import "dart:convert";
import "dart:io";

import "package:dslink/broker.dart";
import "package:dslink/client.dart";
import "package:dslink/server.dart";

BrokerNodeProvider broker;
DsHttpServer server;
LinkProvider link;

const Map<String, String> VARS = const {
  "BROKER_URL": "broker_url",
  "BROKER_LINK_PREFIX": "link_prefix",
  "BROKER_PORT": "port",
  "BROKER_HOST": "host",
  "BROKER_HTTPS_PORT": "https_port",
  "BROKER_CERTIFICATE_NAME": "certificate_name"
};

main(List<String> _args) async {
  var args = new List<String>.from(_args);
  var configFile = new File("broker.json");

  if (args.contains("--docker")) {
    args.remove("--docker");
    var config = {
      "host": "0.0.0.0",
      "port": 8080,
      "link_prefix": "broker-"
    };

    VARS.forEach((n, c) {
      if (Platform.environment.containsKey(n)) {
        config[c] = Platform.environment[n];
      }
    });

    await configFile.writeAsString(JSON.encode(config));
  }

  if (!(await configFile.exists())) {
    await configFile.create(recursive: true);
    await configFile.writeAsString(defaultConfig);
  }

  var config = JSON.decode(await configFile.readAsString());

  dynamic getConfig(String key, [defaultValue]) {
    if (!config.containsKey(key)) {
      return defaultValue;
    }
    return config[key];
  }

  broker = new BrokerNodeProvider();
  server = new DsHttpServer.start(getConfig("host", "0.0.0.0"), httpPort: getConfig("port", -1),
    httpsPort: getConfig("https_port", -1),
    certificateName: getConfig("certificate_name"), nodeProvider: broker, linkManager: broker);

  if (getConfig("broker_url") != null) {
    var url = getConfig("broker_url");
    args.addAll(["--broker", url]);
  }

  if (args.any((it) => it.startsWith("--broker")) || args.contains("-b")) {
    link = new LinkProvider(args, getConfig("link_prefix", "broker-"), nodeProvider: broker)..connect();
  }
}

const String defaultConfig = """{
  "host": "0.0.0.0",
  "port": 8080,
  "link_prefix": "broker-"
}
""";
