library dslink.client;

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:args/args.dart';

import 'common.dart';
import 'requester.dart';
import 'responder.dart';
import 'utils.dart';
import 'src/crypto/pk.dart';
import 'src/http/websocket_conn.dart';

import "package:logging/logging.dart";

import "package:dslink/broker.dart" show BrokerDiscoveryClient;

export "src/crypto/pk.dart";

part 'src/http/client_link.dart';
part 'src/http/client_http_conn.dart';

typedef void OptionResultsHandler(ArgResults results);

/// Main Entry Point for DSLinks on the Dart VM
class LinkProvider {
  HttpClientLink link;
  NodeProvider provider;
  PrivateKey privateKey;
  String brokerUrl;
  File _nodesFile;
  String prefix;
  List<String> args;
  bool isRequester = false;
  String command = 'link';
  bool isResponder = true;
  Map defaultNodes;
  Map profiles;
  bool enableHttp = false;
  bool encodePrettyJson = false;
  bool strictOptions = false;
  bool exitOnFailure = true;
  bool loadNodesJson = true;
  String defaultLogLevel = "INFO";

  LinkProvider(
    this.args,
    this.prefix,
    {
      this.isRequester: false,
      this.command: 'link',
      this.isResponder: true,
      this.defaultNodes,
      this.profiles,
      this.provider,
      this.enableHttp: false,
      this.encodePrettyJson: false,
      bool autoInitialize: true,
      this.strictOptions: false,
      this.exitOnFailure: true,
      this.loadNodesJson: true,
      this.defaultLogLevel: "INFO",
      NodeProvider nodeProvider // For Backwards Compatibility
    }) {
    if (nodeProvider != null) {
      provider = nodeProvider;
    }

    if (autoInitialize) {
      init();
    }
  }

  String _basePath = ".";

  bool _configured = false;

  /// Configure the link.
  /// If [argp] is provided for argument parsing, it is used.
  bool configure({ArgParser argp, OptionResultsHandler optionsHandler}) {
    _configured = true;

    if (link != null) {
      link.close();
      link = null;
    }

    if (argp == null) {
      argp = new ArgParser(allowTrailingOptions: !strictOptions);
    }

    argp.addOption("broker", abbr: "b", help: "Broker URL", defaultsTo: "http://localhost:8080/conn");
    argp.addOption("name", abbr: "n", help: "Link Name");
    argp.addOption("base-path", help: "Base Path for DSLink");
    argp.addOption("log", abbr: "l", allowed: Level.LEVELS.map((it) => it.name).toList()..addAll(["AUTO"]), help: "Log Level", defaultsTo: "AUTO");
    argp.addFlag("help", abbr: "h", help: "Displays this Help Message", negatable: false);
    argp.addFlag("discover", abbr: "d", help: "Automatically Discover a Broker", negatable: false);

    ArgResults opts = argp.parse(args);

    if (opts["log"] == "AUTO") {
      if (DEBUG_MODE) {
        updateLogLevel("ALL");
      } else {
        updateLogLevel(defaultLogLevel);
      }
    } else {
      updateLogLevel(opts["log"]);
    }

    if (opts["base-path"] != null) {
      _basePath = opts["base-path"];

      if (_basePath.endsWith("/")) {
        _basePath = _basePath.substring(0, _basePath.length - 1);
      }
    }

    String helpStr = "usage: $command [--broker URL] [--log LEVEL] [--name NAME] [--discover]";

    if (opts["help"]) {
      print(helpStr);
      print(argp.usage);
      if (exitOnFailure) {
        exit(1);
      } else {
        return false;
      }
    }

    brokerUrl = opts['broker'];
    if (brokerUrl == null && !opts["discover"]) {
      print("No Broker URL Specified. One of [--broker, --discover] is required.");
      print(helpStr);
      print(argp.usage);
      if (exitOnFailure) {
        exit(1);
      } else {
        return false;
      }
    }

    String name = opts["name"];

    if (name != null) {
      if (name.endsWith("-")) {
        prefix = name;
      } else {
        prefix = "${name}-";
      }
    }

    // load configs
    File dslinkFile = new File("${_basePath}/dslink.json");

    if (dslinkFile.existsSync()) {
      var e;
      try {
        String configStr = dslinkFile.readAsStringSync();
        dslinkJson = DsJson.decode(configStr);
      } catch (err) {
        e = err;
      }

      if (dslinkJson == null) {
        logger.severe("Invalid dslink.json", e);
        if (exitOnFailure) {
          exit(1);
        } else {
          return false;
        }
      }
    } else {
      dslinkJson = {};
    }

    if (brokerUrl != null) {
      if (!brokerUrl.startsWith('http')) {
        brokerUrl = 'http://$brokerUrl';
      }
    }

    File keyFile = getConfig('key') == null ? new File("${_basePath}/.dslink.key") : new File.fromUri(Uri.parse(getConfig('key')));
    String key;

    try {
      key = keyFile.readAsStringSync();
      privateKey = new PrivateKey.loadFromString(key);
    } catch (err) {
    }

    if (key == null || key.length != 131) {
      // 43 bytes d, 87 bytes Q, 1 space
      // generate the key
      String macs;
      if (Platform.isWindows) {
        macs = Process.runSync("getmac", []).stdout.toString();
      } else {
        try {
          macs = Process.runSync("arp", ["-an"]).stdout.toString();
        } catch (e) {
          macs = Process.runSync("ifconfig", []).stdout.toString();
        }
      }
      // randomize the PRNG with the system mac (as well as timestamp)
      DSRandom.instance.randomize(macs);
      privateKey = new PrivateKey.generate();
      key = privateKey.saveToString();
      keyFile.writeAsStringSync(key);
    }

    if (opts["discover"]) {
      _discoverBroker = true;
    }

    if (optionsHandler != null) {
      optionsHandler(opts);
    }

    return true;
  }

  /// A Method that a Custom Link Provider can override for changing how to choose a broker.
  /// By default this selects the first broker available.
  Future<String> chooseBroker(Stream<String> brokers) async {
    return await brokers.first;
  }

  bool _discoverBroker = false;

  Stream<ValueUpdate> onValueChange(String path, {int cacheLevel: 1}) {
    RespSubscribeListener listener;
    StreamController<ValueUpdate> controller;
    int subs = 0;
    controller = new StreamController<ValueUpdate>.broadcast(onListen: () {
      subs++;
      if (listener == null) {
        listener = this[path].subscribe((ValueUpdate update) {
          controller.add(update);
        }, cacheLevel);
      }
    }, onCancel: () {
      subs--;
      if (subs == 0) {
        listener.cancel();
        listener = null;
      }
    });
    return controller.stream;
  }

  void syncValue(String path) {
    var n = this[path];
    n.updateValue(n.lastValueUpdate.value, force: true);
  }

  /// Initializes the Link.
  /// There is no guarantee that the link will be ready when this method returns.
  /// If the [configure] method is not called prior to calling this method, it is called.
  void init() {
    if (!_configured) {
      if (!configure()) {
        return;
      }
    }

    _initialized = true;

    if (provider == null) {
      provider = new SimpleNodeProvider(null, profiles);
    }

    if (loadNodesJson && provider is SerializableNodeProvider) {
      _nodesFile = getConfig('nodes') == null ? new File("${_basePath}/nodes.json") : new File.fromUri(Uri.parse(getConfig('nodes')));
      Map loadedNodesData;

      try {
        String nodesStr = _nodesFile.readAsStringSync();
        loadedNodesData = DsJson.decode(nodesStr);
      } catch (err) {
      }

      if (loadedNodesData != null) {
        (provider as SerializableNodeProvider).init(loadedNodesData);
      } else if (defaultNodes != null) {
        (provider as SerializableNodeProvider).init(defaultNodes);
      }
    }

    void doRun() {
      link = new HttpClientLink(
          brokerUrl,
          prefix,
          privateKey,
          isRequester: isRequester,
          isResponder: isResponder,
          nodeProvider: provider,
          enableHttp: enableHttp
      );
      _ready = true;

      if (_connectOnReady) {
        connect();
      }
    }

    if (_discoverBroker) {
      var discovery = new BrokerDiscoveryClient();
      new Future(() async {
        await discovery.init();
        try {
          var broker = await chooseBroker(discovery.discover());
          print("Discovered Broker at ${broker}");
          brokerUrl = broker;
          doRun();
        } catch (e) {
          print("Failed to discover a broker.");
          exit(1);
        }
      });
    } else {
      doRun();
    }
  }

  Map dslinkJson;

  /// Gets a configuration from the dslink.json
  Object getConfig(String key) {
    if (dslinkJson != null &&
      dslinkJson['configs'] is Map &&
      dslinkJson['configs'][key] is Map &&
      dslinkJson['configs'][key].containsKey('value')) {
      return dslinkJson['configs'][key]['value'];
    }
    return null;
  }

  bool _initialized = false;
  bool _ready = false;
  bool _connectOnReady = false;

  Future connect() {
    if (_connectedCompleter == null) {
      _connectedCompleter = new Completer();
    }

    if (!_configured || !_initialized) {
      init();
    }

    if (_ready) {
      link.onConnected.then(_connectedCompleter.complete);
      if (link != null) link.connect();
    } else {
      _connectOnReady = true;
    }
    return _connectedCompleter.future;
  }

  Completer _connectedCompleter;

  Requester get requester => link.requester;

  Future<Requester> get onRequesterReady => link.onRequesterReady;

  void close() {
    _connectedCompleter = null;
    if (link != null) {
      link.close();
      link = null;
    }
  }

  void stop() => close();

  bool get didInitializationFail => link == null;
  bool get isInitialized => link != null;

  void save() {
    if (_nodesFile != null && provider != null) {
      if (provider is! SerializableNodeProvider) {
        return;
      }

      _nodesFile.writeAsStringSync(DsJson.encode((provider as SerializableNodeProvider).save(), pretty: encodePrettyJson));
    }
  }

  Future saveAsync() async {
    if (_nodesFile != null && provider != null) {
      if (provider is! SerializableNodeProvider) {
        return;
      }

      var encoded = DsJson.encode((provider as SerializableNodeProvider).save(), pretty: encodePrettyJson);

      await _nodesFile.writeAsString(encoded);
    }
  }

  LocalNode getNode(String path) {
    return provider.getNode(path);
  }

  LocalNode addNode(String path, Map m) {
    if (provider is! MutableNodeProvider) {
      throw new Exception("Unable to Modify Node Provider: It is not mutable.");
    }
    return (provider as MutableNodeProvider).addNode(path, m);
  }

  void removeNode(String path) {
    if (provider is! MutableNodeProvider) {
      throw new Exception("Unable to Modify Node Provider: It is not mutable.");
    }
    (provider as MutableNodeProvider).removeNode(path);
  }

  void updateValue(String path, dynamic value) {
    if (provider is! MutableNodeProvider) {
      throw new Exception("Unable to Modify Node Provider: It is not mutable.");
    }
    (provider as MutableNodeProvider).updateValue(path, value);
  }

  LocalNode operator [](String path) => provider[path];
}
