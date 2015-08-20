part of dslink.broker;

/// Wrapper node for brokers
class BrokerNode extends LocalNodeImpl with BrokerNodePermission{
  final BrokerNodeProvider provider;
  BrokerNode(String path, this.provider) : super(path);

  @override
  void load(Map m) {
    super.load(m);
    if (m['?permissions'] is List) {
      loadPermission(m['?permissions']);
    }
  }

  @override
  Map serialize(bool withChildren) {
    Map rslt = super.serialize(withChildren);
    List permissionData = this.serializePermission();
    if (permissionData != null) {
      rslt['?permissions'] = permissionData;
    }
    return rslt;
  }

  @override
  int getPermission(Iterator<String> paths, Responder responder, int permission) {
    permission = super.getPermission(paths, responder, permission);
    if (permission == Permission.CONFIG) {
      return Permission.CONFIG;
    }
    if (paths.moveNext()) {
      String name = paths.current;
      if (children[name] is BrokerNodePermission) {
        return (children[name] as BrokerNodePermission).getPermission(paths, responder, permission);
      }
    }
    return permission;
  }
}
/// nodes that automatic add itself to broker tree and always stay there
class BrokerStaticNode extends BrokerNode {
  BrokerStaticNode(String path, BrokerNodeProvider provider) : super(path, provider) {
    provider.setNode(path, this);
  }
}
/// Version node
class BrokerVersionNode extends BrokerStaticNode {
  static BrokerVersionNode instance;
  BrokerVersionNode(String path, BrokerNodeProvider provider, String version) : super(path, provider) {
    instance = this;
    configs[r"$type"] = "string";
    updateValue(version);
  }
}

/// Start Time node
class StartTimeNode extends BrokerStaticNode {
  static StartTimeNode instance;
  StartTimeNode(String path, BrokerNodeProvider provider) : super(path, provider) {
    instance = this;
    configs[r"$type"] = "time";
    updateValue(ValueUpdate.getTs());
  }
}

/// Clear Conns node
class ClearConnsAction extends BrokerStaticNode {

  ClearConnsAction(String path, BrokerNodeProvider provider) : super(path, provider) {
    configs[r"$name"] = "Clear Conns";
    configs[r"$invokable"] = "read";
  }

  @override
  InvokeResponse invoke(Map params, Responder responder,
      InvokeResponse response, LocalNode parentNode,
      [int maxPermission = Permission.CONFIG]) {
    provider.clearConns();
    return response..close();
  }
}

class RootNode extends BrokerNode {
  RootNode(String path, BrokerNodeProvider provider) : super(path, provider) {
    configs[r'$is'] = 'dsa/broker';
  }

  bool _loaded = false;

  void load(Map m) {
    if (_loaded) {
      throw 'root node can not be initialized twice';
    }

    m.forEach((String key, value) {
      if (key.startsWith(r'$')) {
        configs[key] = value;
      } else if (key.startsWith('@')) {
        attributes[key] = value;
      } else if (value is Map) {
        BrokerNode node;
        if (value == 'defs') {
          node = new BrokerHiddenNode('/$key', provider);
        } else {
          node = new BrokerNode('/$key', provider);
        }
        
        node.load(value);
        provider.nodes[node.path] = node;
        children[key] = node;
      }
    });
  }
}

class UpstreamNode extends BrokerStaticNode {
  UpstreamNode(String path, BrokerNodeProvider provider)
  : super(path, provider) {
    new Future(() {
      var cubn = new CreateUpstreamBrokerNode(
          "/sys/upstream/add_connection", provider);
      provider.setNode("/sys/upstream/add_connection", cubn);
    });
  }

  void addUpstreamConnection(String name, String url, String ourName,
                             [bool enabled = true]) {
    if (enabled == null) {
      enabled = true;
    }

    var node = new UpstreamBrokerNode(
        "/sys/upstream/${name}", name, url, ourName, provider);
    provider.setNode("/sys/upstream/${name}", node);
    (provider.getOrCreateNode("/sys/upstream", false) as BrokerNode).updateList(r"$is");
    node.enabled = enabled;
    node.start();
  }

  void removeUpstreamConnection(String name) {
    LocalNode node = provider.getOrCreateNode("/sys/upstream/${name}", false);
    if (node is UpstreamBrokerNode) {
      node.stop();
      node.toBeRemoved = true;
      children.remove(name);
      updateList(name);
    }
  }

  void loadConfigMap(Map x) {
    for (var k in x.keys) {
      var m = x[k];
      addUpstreamConnection(k, m["url"], m["name"], m["enabled"]);
    }
  }

  Map getConfigMap() {
    List<UpstreamBrokerNode> ubns = provider.nodes.keys.where((x) {
      try {
        if (x.startsWith("/sys/upstream/") &&
        x != "/sys/upstream/add_connection") {
          return x.codeUnits.where((l) => l == "/".codeUnitAt(0)).length == 3;
        } else {
          return false;
        }
      } catch (e) {
        return false;
      }
    }).map((x) => provider.getOrCreateNode(x, false))
      .where((x) => x != null)
      .where((x) => x is UpstreamBrokerNode)
      .where((UpstreamBrokerNode x) => !x.toBeRemoved)
      .toList();

    var map = {};

    ubns.forEach((x) {
      map[x.name] = {"name": x.ourName, "url": x.url, "enabled": x.enabled};
    });

    return map;
  }
}

class EnableUpstreamBrokerNode extends BrokerNode {
  EnableUpstreamBrokerNode(String path, BrokerNodeProvider provider)
  : super(path, provider) {
    configs[r"$name"] = "Enable";
    configs[r"$invokable"] = "write";
  }

  @override
  InvokeResponse invoke(
      Map params, Responder responder, InvokeResponse response, Node parentNode,
      [int maxPermission = Permission.CONFIG]) {
    var p = new Path(path).parentPath;
    UpstreamBrokerNode un = provider.getOrCreateNode(p, false);
    un.enabled = true;
    un.start();
    return response..close();
  }
}

class DisableUpstreamBrokerNode extends BrokerNode {
  DisableUpstreamBrokerNode(String path, BrokerNodeProvider provider)
  : super(path, provider) {
    configs[r"$name"] = "Disable";
    configs[r"$invokable"] = "write";
  }

  @override
  InvokeResponse invoke(
      Map params, Responder responder, InvokeResponse response, Node parentNode,
      [int maxPermission = Permission.CONFIG]) {
    var p = new Path(path).parentPath;
    UpstreamBrokerNode un = provider.getOrCreateNode(p, false);
    un.enabled = false;
    un.stop();
    return response..close();
  }
}

class CreateUpstreamBrokerNode extends BrokerNode {
  CreateUpstreamBrokerNode(String path, BrokerNodeProvider provider)
  : super(path, provider) {
    configs[r"$name"] = "Add Upstream Connection";
    configs[r"$invokable"] = "write";
    configs[r"$params"] = [
      {
        "name": "name",
        "type": "string",
        "description": "Upstream Broker Name",
        "placeholder": "UpstreamBroker"
      },
      {
        "name": "url",
        "type": "string",
        "description": "Url to the Upstream Broker",
        "placeholder": "http://upstream.broker.com/conn"
      },
      {
        "name": "brokerName",
        "type": "string",
        "description":
        "The name of the link when connected to the Upstream Broker",
        "placeholder": "ThisBroker"
      }
    ];

    configs[r"$result"] = "values";
  }

  @override
  InvokeResponse invoke(
      Map params, Responder responder, InvokeResponse response, Node parentNode,
      [int maxPermission = Permission.CONFIG]) {
    var name = params["name"];
    var ourName = params["brokerName"];
    var url = params["url"];
    var b = provider.getOrCreateNode("/sys/upstream", false) as UpstreamNode;
    b.addUpstreamConnection(name, url, ourName);
    return response..close();
  }
}

class DeleteUpstreamConnectionNode extends BrokerNode {
  final String name;

  DeleteUpstreamConnectionNode(
      String path, this.name, BrokerNodeProvider provider)
  : super(path, provider) {
    configs[r"$name"] = "Remove";
    configs[r"$invokable"] = "write";
    configs[r"$result"] = "values";
  }

  @override
  InvokeResponse invoke(
      Map params, Responder responder, InvokeResponse response, Node parentNode,
      [int maxPermission = Permission.CONFIG]) {
    var b = provider.getOrCreateNode("/sys/upstream", false) as UpstreamNode;
    b.removeUpstreamConnection(name);
    return response..close();
  }
}

class UpstreamBrokerNode extends BrokerNode {
  final String name;
  final String url;
  final String ourName;

  BrokerNode ien;
  BrokerNode nn;
  bool enabled = false;

  bool toBeRemoved = false;

  LinkProvider link;

  UpstreamBrokerNode(String path, this.name, this.url, this.ourName,
                     BrokerNodeProvider provider)
  : super(path, provider) {
    ien = new BrokerNode("/sys/upstream/${name}/enabled", provider);
    ien.configs[r"$type"] = "bool";
    ien.updateValue(enabled);

    nn = new BrokerNode("/sys/upstream/${name}/name", provider);
    nn.configs[r"$type"] = "string";
    nn.updateValue(this.ourName);

    new Future(() {
      var drn = new DeleteUpstreamConnectionNode(
          "/sys/upstream/${name}/delete", name, provider);
      provider.setNode("/sys/upstream/${name}/delete", drn);
      var eun = new EnableUpstreamBrokerNode(
          "/sys/upstream/${name}/enable", provider);
      provider.setNode("/sys/upstream/${name}/enable", eun);
      var dun = new DisableUpstreamBrokerNode(
          "/sys/upstream/${name}/disable", provider);
      provider.setNode("/sys/upstream/${name}/disable", dun);
      provider.setNode(ien.path, ien);
      provider.setNode(nn.path, nn);
      addChild("delete", drn);
      addChild("enable", eun);
      addChild("disable", dun);
      addChild("enabled", ien);
      addChild("name", nn);
    });
  }

  void start() {
    if (!enabled) {
      return;
    }

    BrokerNodeProvider p = provider;
    var level = logger.level;
    String upstreamId = '@upstream@$name';
    Requester overrideRequester = provider.getRequester(upstreamId);
    Responder overrideResponder = provider.getResponder(upstreamId, provider);
    link = new LinkProvider(["--broker=${url}"], ourName + "-", enableHttp: false, nodeProvider: p, isRequester: true,
        overrideRequester:overrideRequester, overrideResponder:overrideResponder);

    link.init();

    logger.level = level;

    link.connect();

    RemoteLinkManager linkManager = p.addUpStreamLink(link.link, name);

    ien.updateValue(true);
    enabled = true;
    link.onRequesterReady.then((Requester requester){
      if (link.link.remotePath != null) {
        linkManager.rootNode.configs[r'$remotePath'] = link.link.remotePath;
        linkManager.rootNode.updateList(r'$remotePath');
      }
    });
  }

  void stop() {
    if (link == null) {
      return;
    }

    link.stop();
    BrokerNodeProvider p = provider;

    p.removeLink(link.link, '@upstream@$name');
    ien.updateValue(false);
    enabled = false;
  }
}


class BrokerHiddenNode extends BrokerNode {
  BrokerHiddenNode(String path, BrokerNodeProvider provider) : super(path, provider) {
    configs[r'$hidden'] = true;
  }

  Map getSimpleMap() {
    Map rslt = {r'$hidden':true};
    if (configs.containsKey(r'$is')) {
      rslt[r'$is'] = configs[r'$is'];
    }
    if (configs.containsKey(r'$type')) {
      rslt[r'$type'] = configs[r'$type'];
    }
    if (configs.containsKey(r'$name')) {
      rslt[r'$name'] = configs[r'$name'];
    }
    if (configs.containsKey(r'$invokable')) {
      rslt[r'$invokable'] = configs[r'$invokable'];
    }
    if (configs.containsKey(r'$writable')) {
      rslt[r'$writable'] = configs[r'$writable'];
    }
    // TODO add permission of current requester
    return rslt;
  }
}