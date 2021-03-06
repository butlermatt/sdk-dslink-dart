part of dslink.responder;

class RespSubscribeListener {
  Function callback;
  LocalNode node;
  RespSubscribeListener(this.node, this.callback);
  void cancel() {
    if (callback != null) {
      node.unsubscribe(callback);
      callback = null;
    }
  }
}

class SubscribeResponse extends Response {
  SubscribeResponse(Responder responder, int rid) : super(responder, rid);

  final Map<String, RespSubscribeController> subsriptions =
      new Map<String, RespSubscribeController>();
  final Map<int, RespSubscribeController> subsriptionids =
      new Map<int, RespSubscribeController>();

  final LinkedHashSet<RespSubscribeController> changed =
      new LinkedHashSet<RespSubscribeController>();

  RespSubscribeController add(String path, LocalNode node, int sid, int qos) {
    RespSubscribeController controller;
    if (subsriptions[path] != null) {
      controller = subsriptions[path];
      if (controller.sid != sid) {
        if (controller.sid >= 0) {
          subsriptionids.remove(controller.sid);
        }
        controller.sid = sid;
        if (sid >= 0) {
          subsriptionids[sid] = controller;
        }
      }
      controller.qosLevel = qos;
      if (sid > -1 && controller.lastValue != null) {
        subscriptionChanged(controller);
      }
    } else {
      int permission = responder.nodeProvider.permissions
          .getPermission(node.path, responder);
      controller = new RespSubscribeController(
          this, node, sid, permission >= Permission.READ, qos);
      subsriptions[path] = controller;
      if (sid >= 0) {
        subsriptionids[sid] = controller;
      }
      if (responder._traceCallbacks != null){
        ResponseTrace update = new ResponseTrace(path,'subscribe',0,'+');
        for (ResponseTraceCallback callback in responder._traceCallbacks) {
          callback(update);
        }  
      }
    }
    return controller;
  }

  void remove(int sid) {
    if (subsriptionids[sid] != null) {
      RespSubscribeController controller = subsriptionids[sid];
      subsriptionids[sid].destroy();
      subsriptionids.remove(sid);
      subsriptions.remove(controller.node.path);
      if (responder._traceCallbacks != null){
        ResponseTrace update = new ResponseTrace(controller.node.path,'subscribe',0,'-');
        for (ResponseTraceCallback callback in responder._traceCallbacks) {
          callback(update);
        }  
      }
    }
  }

  void subscriptionChanged(RespSubscribeController controller) {
    changed.add(controller);
    prepareSending();
  }
  @override
  void startSendingData(int currentTime, int waitingAckId) {
    _pendingSending = false;
    
    if (waitingAckId != -1) {
      _waitingAckCount++;
      _lastWatingAckId = waitingAckId;
    }
  
    List updates = [];
    for (RespSubscribeController controller in changed) {
      if (controller.sid == -1) {
        int debuga = 1;
      }
      updates.addAll(controller.process(waitingAckId));
    }
    responder.updateResponse(this, updates);
    changed.clear();
  }

  int _waitingAckCount = 0;
  int _lastWatingAckId = -1;
   
  void ackReceived(int receiveAckId, int startTime, int currentTime) {
    if (receiveAckId == _lastWatingAckId) {
      _waitingAckCount = 0;
    } else {
      _waitingAckCount --;
    }
    subsriptions.forEach((String path, RespSubscribeController controller){
      if (controller._qosLevel > 0) {
        controller.onAck(receiveAckId);
      }
    });
    if (_sendingAfterAck) {
      _sendingAfterAck = false;
      prepareSending();
    }
  }
  bool _sendingAfterAck = false;
  void prepareSending() {
    if (_sendingAfterAck) {
      return;
    }
    if (_waitingAckCount > ConnectionProcessor.ACK_WAIT_COUNT) {
      _sendingAfterAck = true;
      return;
    }
    if (responder.connection == null) {
      // don't pend send, when requester is offline
      return;
    }
    if (!_pendingSending) {
      _pendingSending = true;
      responder.addProcessor(this);
    }
  }
  
  void _close() {
    List pendingControllers;
    subsriptions.forEach((path, RespSubscribeController controller) {
      if (controller._qosLevel == 0) {
        controller.destroy();
      } else {
        controller.sid = -1;
        if (pendingControllers == null) {
          pendingControllers = [];
        }
        pendingControllers.add(controller);
      }
    });
    subsriptions.clear();
    if (pendingControllers != null) {
      for (RespSubscribeController controller in pendingControllers) {
        subsriptions[controller.node.path] = controller;
      }
    }
    
    subsriptionids.clear();
    _waitingAckCount = 0;
    _lastWatingAckId = -1;
    _sendingAfterAck = false;
  }
  void addTraceCallback(ResponseTraceCallback _traceCallback) {
    subsriptions.forEach((path, controller) {
      ResponseTrace update = new ResponseTrace(controller.node.path,'subscribe',0,'+');
      _traceCallback(update);
    });
  }
}

class RespSubscribeController {
  final LocalNode node;
  final SubscribeResponse response;
  RespSubscribeListener _listener;
  int sid;

  bool _permitted = true;
  void set permitted(bool val) {
    if (val == _permitted) return;
    _permitted = val;
    if (_permitted && lastValues.length > 0) {
      response.subscriptionChanged(this);
    }
  }

  List<ValueUpdate> lastValues = new List<ValueUpdate>();
  ListQueue<ValueUpdate> waitingValues;//; = new ListQueue<ValueUpdate>();
  ValueUpdate lastValue;
    
  int _qosLevel = -1;
  ISubscriptionNodeStorage _storage;
  
  void set qosLevel(int v) {
    if (v < 0 || v > 3) v = 0;
    if (_qosLevel == v) 
      return;
    
    _qosLevel = v;
    if (waitingValues == null && _qosLevel > 0) {
      waitingValues = new ListQueue<ValueUpdate>(); 
    }
    caching = (v&1) == 1;
    persist = (v&2) == 2;
  }
  
  bool _caching = false;
  void set caching(bool val) {
    if (val == _caching) return;
    _caching = val;
    if (!_caching) {
      lastValues.clear();
    }
  }
  bool _persist = false;
  void set persist(bool val) {
    if (val == _persist) return;
    _persist = val;
    ISubscriptionResponderStorage storageM = response.responder.storage;
    if (storageM != null) {
      if (_persist) {
        _storage = storageM.getOrCreateValue(node.path);
      } else if (_storage != null){
        storageM.destroyValue(node.path);
        _storage = null;
      }
    }
  }

  RespSubscribeController(
      this.response, this.node, this.sid, this._permitted, int qos) {
    this.qosLevel = qos;
    _listener = node.subscribe(addValue, _qosLevel);
    if (node.valueReady && node.lastValueUpdate != null) {
      addValue(node.lastValueUpdate);
    }
  }

  bool _isCacheValid = true;
  void addValue(ValueUpdate val) {
    if (_caching && _isCacheValid) {
      lastValues.add(val);
      if (lastValues.length > response.responder.maxCacheLength) {
        // cache is no longer valid, fallback to rollup mode
        _isCacheValid = false;
        lastValue = new ValueUpdate(null,ts:'');
        for (ValueUpdate update in lastValues) {
          lastValue.mergeAdd(update);
        }
        lastValues.clear();
        if (_qosLevel > 0) {
          if (_storage != null) {
              _storage.setValue(waitingValues, lastValue);
          }
          waitingValues..clear()..add(lastValue);
        }
      } else {
        lastValue = val;
        if (_qosLevel > 0) {
          waitingValues.add(lastValue);
          if (_storage != null) {
              _storage.addValue(lastValue);
          }
        }
      }
    } else {
      if (lastValue != null) {
        lastValue =  new ValueUpdate.merge(lastValue, val);
      } else {
        lastValue = val;
      }
      if (_qosLevel > 0) {
         if (_storage != null) {
             _storage.setValue(waitingValues, lastValue);
         }
         waitingValues..clear()..add(lastValue);
      }
    }
    // TODO, don't allow this to be called from same controller more oftern than 100ms
    // the first response can happen ASAP, but
    if (_permitted && sid > -1) {
      response.subscriptionChanged(this);
    }
  }

  List process(int waitingAckId) {
    List rslts = [];
    if (_caching && _isCacheValid) {
      for (ValueUpdate lastValue in lastValues) {
        rslts.add([sid, lastValue.value, lastValue.ts]);
      }
      if (_qosLevel > 0) {
        for (ValueUpdate update in lastValues) {
          update.waitingAck = waitingAckId;
        }
      }
      lastValues.clear();
    } else {
      if (lastValue.count > 1 || lastValue.status != null) {
        Map m = lastValue.toMap();
        m['sid'] = sid;
        rslts.add(m);
      } else {
        rslts.add([sid, lastValue.value, lastValue.ts]);
      }
      if (_qosLevel > 0) {
        lastValue.waitingAck = waitingAckId;
      }
      _isCacheValid = true;
    }
    lastValue = null;
    return rslts;
  }
  
  void onAck(int ackId) {
    if (waitingValues.isEmpty) {
      return;
    }
    bool valueRemoved = false;
    if (!waitingValues.isEmpty && waitingValues.first.waitingAck != ackId) {
      print('invalidAck ${waitingValues.first.value} ${waitingValues.first.waitingAck}');
      
      ValueUpdate matchUpdate;
      for(ValueUpdate update in waitingValues) {
        if (update.waitingAck == ackId) {
          matchUpdate = update;
          break;
        }
      }
      if (matchUpdate != null) {
        while (!waitingValues.isEmpty && waitingValues.first != matchUpdate) {
          ValueUpdate removed = waitingValues.removeFirst();
          if (_storage != null) {
            _storage.removeValue(removed);
            valueRemoved = true;
          }
        }
      }
    }
    while (!waitingValues.isEmpty && waitingValues.first.waitingAck == ackId) {
      ValueUpdate removed = waitingValues.removeFirst();
      if (_storage != null) {
        _storage.removeValue(removed);
        valueRemoved = true;
      }
    }
    if (valueRemoved && _storage != null) {
      _storage.valueRemoved(waitingValues);
    }
  }

  void resetCache(List<ValueUpdate> values) {
    if (this._caching) {
      if (lastValues.length > 0 && lastValues.first.equals(values.last)) {
        lastValues.removeAt(0);
      }
      lastValues = values..addAll(lastValues);
      if (waitingValues != null) {
        waitingValues.clear();
        waitingValues.addAll(lastValues);
      }
    } else {
      lastValues.clear();
      if (waitingValues != null) {
        waitingValues.clear();
        waitingValues.add(values.last);
      }
    }
    lastValue = values.last;
  }
  void destroy() {
    if (_storage != null) {
      ISubscriptionResponderStorage storageM = response.responder.storage;
      storageM.destroyValue(node.path);
      _storage = null;
    }
    _listener.cancel();
  }
}
