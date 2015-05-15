library dslink.worker;

import "dart:async";
import "dart:isolate";

typedef void WorkerFunction(Worker worker);
typedef Producer(input);

WorkerSocket createWorker(WorkerFunction function, {Map<String, dynamic> metadata}) {
  var receiver = new ReceivePort();
  var socket = new WorkerSocket.master(receiver);
  Isolate.spawn(function, new Worker(receiver.sendPort, metadata)).then((x) {
    socket._isolate = x;
  });
  return socket;
}

Worker buildWorkerForScript(Map data) {
  return new Worker(data["port"], data["metadata"]);
}

WorkerSocket createWorkerScript(script, {List<String> args, Map<String, dynamic> metadata}) {
  var receiver = new ReceivePort();
  var socket = new WorkerSocket.master(receiver);
  Uri uri;

  if (script is Uri) {
    uri = script;
  } else if (script is String) {
    uri = Uri.parse(script);
  } else {
    throw new ArgumentError.value(script, "script", "should be either a Uri or a String.");
  }

  Isolate.spawnUri(uri, [], {
    "port": receiver.sendPort,
    "metadata": metadata
  }).then((x) {
    socket._isolate = x;
  });
  return socket;
}

WorkerPool createWorkerScriptPool(int count, Uri uri, {Map<String, dynamic> metadata}) {
  var workers = [];
  for (var i = 1; i <= count; i++) {
    workers.add(createWorkerScript(uri, metadata: {
      "workerId": i
    }..addAll(metadata == null ? {} : metadata)));
  }
  return new WorkerPool(workers);
}

WorkerPool createWorkerPool(int count, WorkerFunction function, {Map<String, dynamic> metadata}) {
  var workers = [];
  for (var i = 1; i <= count; i++) {
    workers.add(createWorker(function, metadata: {
      "workerId": i
    }..addAll(metadata == null ? {} : metadata)));
  }
  return new WorkerPool(workers);
}

class WorkerPool {
  final List<WorkerSocket> sockets;

  WorkerPool(this.sockets) {
    for (var i = 0; i < sockets.length; i++) {
      _workCounts[i] = 0;
    }
  }

  Future waitFor() {
    return Future.wait(sockets.map((it) => it.waitFor()).toList());
  }

  Future stop() {
    return Future.wait(sockets.map((it) => it.stop()).toList());
  }

  Future ping() {
    return Future.wait(sockets.map((it) => it.ping()).toList());
  }

  void send(dynamic data) {
    forEach((socket) => socket.send(data));
  }

  void listen(void handler(int worker, event)) {
    var i = 0;
    for (var worker in sockets) {
      var id = i;
      worker.listen((e) {
        handler(id, e);
      });
      i++;
    }
  }

  Future<WorkerPool> init() => Future.wait(sockets.map((it) => it.init()).toList()).then((_) => this);

  void forEach(void handler(WorkerSocket socket)) {
    sockets.forEach(handler);
  }

  void addMethod(String name, Producer handler) {
    forEach((socket) => socket.addMethod(name, handler));
  }

  Future<List<dynamic>> callMethod(String name, [argument]) {
    return Future.wait(sockets.map((it) => it.callMethod(name, argument)).toList());
  }

  Future<dynamic> divide(String name, int count, {dynamic next(), dynamic collect(List<dynamic> inputs)}) async {
    if (next == null) {
      var i = 0;
      next = () {
        return i++;
      };
    }

    var futures = [];
    for (var i = 1; i <= count; i++) {
      var input = next();
      futures.add(getAvailableWorker().callMethod(name, input));
    }

    var outs = await Future.wait(futures);

    return collect != null ? await collect(outs) : outs;
  }

  Future<dynamic> distribute(String name, [argument]) {
    return getAvailableWorker().callMethod(name, argument);
  }

  void resetDistributionCache() {
    for (var i in _workCounts.keys.toList()) {
      _workCounts[i] = 0;
    }
  }

  int getAvailableWorkerId() {
    var ids = _workCounts.keys.toList();
    ids.sort((a, b) => _workCounts[a].compareTo(_workCounts[b]));
    var best = ids.first;
    _workCounts[best] = _workCounts[best] + 1;
    return best;
  }

  WorkerSocket getAvailableWorker() {
    return workerAt(getAvailableWorkerId());
  }

  Map<int, int> _workCounts = {};

  WorkerSocket workerAt(int id) => sockets[id];
  WorkerSocket operator [](int id) => workerAt(id);
}

class Worker {
  final SendPort port;
  final Map<String, dynamic> metadata;

  Worker(this.port, [Map<String, dynamic> meta])
  : metadata = meta == null ? {} : meta;

  WorkerSocket createSocket() => new WorkerSocket.worker(port);
  Future<WorkerSocket> init({Map<String, Producer> methods}) async => await createSocket().init(methods: methods);

  dynamic get(String key) => metadata[key];
  bool has(String key) => metadata.containsKey(key);
}

typedef Future<T> WorkerMethod<T>([argument]);

class WorkerSocket extends Stream<dynamic> implements StreamSink<dynamic> {
  final ReceivePort receiver;
  SendPort _sendPort;

  WorkerSocket.master(this.receiver) : isWorker = false {
    receiver.listen((msg) {
      if (msg == null || msg is! Map) {
        return;
      }

      String type = msg["type"];

      if (type == null) {
        return;
      }

      if (type == "send_port") {
        _sendPort = msg["port"];
        _readyCompleter.complete();
      } else if (type == "data") {
        _controller.add(msg["data"]);
      } else if (type == "error") {
        _controller.addError(msg["error"]);
      } else if (type == "ping") {
        _sendPort.send(msg["id"]);
      } else if (type == "pong") {
        var id = msg["id"];
        if (_pings.containsKey(id)) {
          _pings[id].complete();
          _pings.remove(id);
        }
      } else if (type == "request") {
        _handleRequest(msg["name"], msg["id"], msg["argument"]);
      } else if (type == "response") {
        var id = msg["id"];
        var result = msg["result"];
        if (_responseHandlers.containsKey(id)) {
          _responseHandlers.remove(id).complete(result);
        } else {
          throw new Exception("Invalid Request ID: ${id}");
        }
      } else if (type == "stopped") {
        _stopCompleter.complete();
      } else {
        throw new Exception("Unknown message: ${msg}");
      }
    });
  }

  WorkerSocket.worker(SendPort port)
  : _sendPort = port,
  receiver = new ReceivePort(),
  isWorker = true {
    _sendPort.send({
      "type": "send_port",
      "port": receiver.sendPort
    });

    receiver.listen((msg) {
      if (msg == null || msg is! Map) {
        return;
      }

      String type = msg["type"];

      if (type == null) {
        return;
      }

      if (type == "data") {
        _controller.add(msg["data"]);
      } else if (type == "error") {
        _controller.addError(msg["error"]);
      } else if (type == "stop") {
        _stopCompleter.complete();
        _sendPort.send({
          "type": "stopped"
        });
      } else if (type == "ping") {
        _sendPort.send({
          "type": "pong",
          "id": msg["id"]
        });
      } else if (type == "pong") {
        var id = msg["id"];
        if (_pings.containsKey(id)) {
          _pings[id].complete();
          _pings.remove(id);
        }
      } else if (type == "request") {
        _handleRequest(msg["name"], msg["id"], msg["argument"]);
      } else if (type == "response") {
        var id = msg["id"];
        var result = msg["result"];
        if (_responseHandlers.containsKey(id)) {
          _responseHandlers.remove(id).complete(result);
        } else {
          throw new Exception("Invalid Request ID: ${id}");
        }
      } else {
        throw new Exception("Unknown message: ${msg}");
      }
    });
  }

  Map<int, Completer> _pings = {};

  final bool isWorker;

  bool get isMaster => !isWorker;

  Future waitFor() {
    if (isWorker) {
      return new Future.value();
    } else {
      return _readyCompleter.future;
    }
  }

  Future<WorkerSocket> init({Map<String, Producer> methods}) {
    if (methods != null) {
      for (var key in methods.keys) {
        addMethod(key, methods[key]);
      }
    }
    return waitFor().then((_) => this);
  }

  void addMethod(String name, Producer producer) {
    _requestHandlers[name] = producer;
  }

  Future callMethod(String name, [argument]) {
    var completer = new Completer();
    _responseHandlers[_reqId] = completer;
    _sendPort.send({
      "type": "request",
      "id": _reqId,
      "name": name,
      "argument": argument
    });
    _reqId++;
    return completer.future;
  }

  WorkerMethod<dynamic> getMethod(String name) => ([argument]) =>
  callMethod(name, argument);

  int _reqId = 0;

  void _handleRequest(String name, int id, argument) {
    if (_requestHandlers.containsKey(name)) {
      var val = _requestHandlers[name](argument);
      new Future.value(val).then((result) {
        _sendPort.send({
          "type": "response",
          "id": id,
          "result": result
        });
      });
    } else {
      throw new Exception("Invalid Method: ${name}");
    }
  }

  Map<int, Completer> _responseHandlers = {};
  Map<String, Producer> _requestHandlers = {};

  Completer _readyCompleter = new Completer();

  int _pingId = 0;

  Future ping() {
    var completer = new Completer();
    _pings[_pingId] = completer;
    _sendPort.send({
      "type": "ping",
      "id": _pingId
    });
    _pingId++;
    return completer.future;
  }

  @override
  void add(event) {
    _sendPort.send({
      "type": "data",
      "data": event
    });
  }

  void send(event) => add(event);

  @override
  void addError(errorEvent, [StackTrace stackTrace]) {
    _sendPort.send({
      "type": "error",
      "error": errorEvent
    });
  }

  @override
  Future addStream(Stream stream) {
    return stream.listen((data) {
      add(data);
    }).asFuture();
  }

  Future stop() => close();

  @override
  Future close() {
    _sendPort.send({
      "type": "stop"
    });
    return _stopCompleter.future.then((_) {
      if (isMaster) {
        receiver.close();
      } else {
        return new Future.delayed(new Duration(seconds: 1), () {
          receiver.close();
        });
      }
    });
  }

  @override
  Future get done => _stopCompleter.future;

  Completer _stopCompleter = new Completer();

  @override
  StreamSubscription listen(void onData(event),
                            {Function onError, void onDone(), bool cancelOnError}) {
    return _controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  bool kill() {
    receiver.close();
    if (_isolate != null) {
      _isolate.kill();
      return true;
    } else {
      return false;
    }
  }

  Isolate _isolate;

  StreamController _controller = new StreamController.broadcast();
}
