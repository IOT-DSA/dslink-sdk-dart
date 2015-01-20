part of dslink.responder;

/// node can be subscribed or listed by multiple responder
abstract class ResponderNode extends Node {
  final StreamController<String> listChangeController = new StreamController<String>();
  Stream<String> _listStream;
  Stream<String> get listStream {
    if (_listStream == null) {
      _listStream = listChangeController.stream.asBroadcastStream();
    }
    return _listStream;
  }

  StreamController<ValueUpdate> _valueController;
  StreamController<ValueUpdate> get valueController {
    // lazy initialize
    if (_valueController == null) {
      _valueController = new StreamController<ValueUpdate>();
    }
    return _valueController;
  }
  Stream<ValueUpdate> _valueStream;
  Stream<ValueUpdate> get valueStream {
    if (_valueStream == null) {
      _valueStream = valueController.stream.asBroadcastStream();
    }
    return _valueStream;
  }

  ResponderNode(String path) : super(path);

  /// list and subscribe can be called on a node that doesn't exist
  /// other api like set remove, invoke, can only be applied to existing node
  bool get exists => true;

  /// whether the node is ready for returning a list response
  bool get listReady => true;

  ListResponse list(Responder responder, ListResponse response) {
    return response;
  }
  RespSubscribeController subscribe(SubscribeResponse subscription, Responder responder) {
    return new RespSubscribeController(subscription, this);
  }

  Response invoke(Map params, Responder responder, Response rid);

  Response setAttribute(String name, String value, Responder responder, Response rid);
  Response removeAttribute(String name, Responder responder, Response rid);
  Response setConfig(String name, Object value, Responder responder, Response rid);
  Response removeConfig(String name, Responder responder, Response rid);
  /// set node value
  Response setValue(Object value, Responder responder, Response rid);
}
/// node provider for responder
/// one nodeProvider can be reused by multiple responders
abstract class NodeProvider {
  /// get a existing node or create a dummy node for requester to listen on
  ResponderNode getNode(String path);
}