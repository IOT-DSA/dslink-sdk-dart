part of dslink.server;

class DsSimpleLinkManager implements ServerLinkManager {
  final Map<String, HttpServerLink> _links = new Map<String, HttpServerLink>();

  void addLink(ServerLink link) {
    _links[link.dsId] = link;
  }

  ServerLink getLink(String dsId, {String sessionId:'', String deviceId}) {
    return _links[dsId];
  }

  void removeLink(ServerLink link) {
    if (_links[link.dsId] == link) {
      _links.remove(link.dsId);
    }
  }

  Requester getRequester(String dsId) {
    return new Requester();
  }

  Responder getResponder(String dsId, NodeProvider nodeProvider, [String sessionId = '']) {
    return new Responder(nodeProvider);
  }
}

class DsHttpServer {
  String dsId = "broker-dsa-VLK07CSRoX_bBTQm4uDIcgfU-jV-KENsp52KvDG_o8g";
  String publicKey = "vvOSmyXM084PKnlBz3SeKScDoFs6I_pdGAdPAB8tOKmA5IUfIlHefdNh1jmVfi1YBTsoYeXm2IH-hUZang48jr3DnjjI3MkDSPo1czrI438Cr7LKrca8a77JMTrAlHaOS2Yd9zuzphOdYGqOFQwc5iMNiFsPdBtENTlx15n4NGDQ6e3d8mrKiSROxYB9LrF1-53goDKvmHYnDA_fbqawokM5oA3sWUIq5uNdp55_cF68Lfo9q-ea8JEsHWyDH73FqNjUaPLFdgMl8aYl-sUGpdlMMMDwRq-hnwG3ad_CX5iFkiHpW-uWucta9i3bljXgyvJ7dtVqEUQBH-GaUGkC-w";
  int updateInterval = 200;
  final NodeProvider nodeProvider;
  final ServerLinkManager _linkManager;

  /// to open a secure server, SecureSocket.initialize() need to be called before start()
  DsHttpServer.start(dynamic address, //
      {int httpPort: 8080, int httpsPort: 8443, String certificateName,
      linkManager, this.nodeProvider})
      : _linkManager = (linkManager == null)
          ? new DsSimpleLinkManager()
          : linkManager {
    if (httpPort > 0) {
      HttpServer.bind(address, httpPort).then((server) {
        logger.info('listening on HTTP port $httpPort');
        server.listen(_handleRequest);
      }).catchError((Object err) {
        logger.severe(err);
      });
    }

    if (httpsPort > 0 && certificateName != null) {
      HttpServer
          .bindSecure(address, httpsPort, certificateName: certificateName)
          .then((server) {
        logger.info('listening on HTTPS port $httpsPort');
        server.listen(_handleRequest);
      }).catchError((Object err) {
        logger.severe(err);
      });
    }
  }

  void _handleRequest(HttpRequest request) {
    try {
      String dsId = request.uri.queryParameters['dsId'];

      if (dsId == null || dsId.length < 43) {
        updateResponseBeforeWrite(request, HttpStatus.BAD_REQUEST);
        request.response.close();
        return;
      }

      switch (request.requestedUri.path) {
        case '/conn':
          _handleConn(request, dsId);
          break;
        case '/http':
          _handleHttpUpdate(request, dsId);
          break;
        case '/ws':
          _handleWsUpdate(request, dsId);
          break;
        default:
          updateResponseBeforeWrite(request, HttpStatus.BAD_REQUEST);
          request.response.close();
          break;
      }
    } catch (err) {
      if (err is int) {
        // TODO need protection because changing statusCode itself can throw
        updateResponseBeforeWrite(request, err);
      } else {
        updateResponseBeforeWrite(request);
      }
      request.response.close();
    }
  }

  void _handleConn(HttpRequest request, String dsId) {
    request.fold([], foldList).then((List<int> merged) {
      try {
        if (merged.length > 1024) {
          updateResponseBeforeWrite(request, HttpStatus.BAD_REQUEST);
          // invalid connection request
          request.response.close();
          return;
        } else if (merged.length == 0) {
          updateResponseBeforeWrite(request, HttpStatus.BAD_REQUEST);
          request.response.close();
          return;
        }
        String str = UTF8.decode(merged);
        Map m = DsJson.decode(str);
        HttpServerLink link = _linkManager.getLink(dsId);
        if (link == null) {
          String publicKeyPointStr = m['publicKey'];
          var bytes = Base64.decode(publicKeyPointStr);
          if (bytes == null) {
            // public key is invalid
            throw HttpStatus.BAD_REQUEST;
          }
          link = new HttpServerLink(
              dsId, new PublicKey.fromBytes(bytes), _linkManager,
              nodeProvider: nodeProvider);
          if (!link.valid) {
            // dsId doesn't match public key
            throw HttpStatus.BAD_REQUEST;
          }
          _linkManager.addLink(link);
        }
        link.initLink(request, m['isRequester'] == true, m['isResponder'] == true, dsId, publicKey, updateInterval:updateInterval);
      } catch (err) {
        if (err is int) {
          // TODO need protection because changing statusCode itself can throw
          updateResponseBeforeWrite(request, err);
        } else {
          updateResponseBeforeWrite(request);
        }
        request.response.close();
      }
    });
  }

  void _handleHttpUpdate(HttpRequest request, String dsId) {
    HttpServerLink link = _linkManager.getLink(dsId);
    if (link != null) {
      link.handleHttpUpdate(request);
    } else {
      throw HttpStatus.UNAUTHORIZED;
    }
  }

  void _handleWsUpdate(HttpRequest request, String dsId) {
    HttpServerLink link = _linkManager.getLink(dsId);
    if (link != null) {
      link.handleWsUpdate(request);
    } else {
      throw HttpStatus.UNAUTHORIZED;
    }
  }
}
