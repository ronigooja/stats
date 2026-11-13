import Kit

public final class DataReader: Reader<RemoteSnapshot> {
    private var mqtt: MQTTSubscriber?

    public override func setup() {
        self.interval = 60
        self.value = nil
    }

    public override func start() {
        super.start()
        self.read()
    }

    public override func read() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, MQTTSettings.enabled else { return }
            if self.mqtt == nil {
                let mqtt = MQTTSubscriber()
                mqtt.onSnapshot = { [weak self, weak mqtt] snapshot in
                    guard let self, let mqtt, self.mqtt === mqtt, self.active, MQTTSettings.enabled else { return }
                    // Reader.callback forwards values to the official service. Keep broker data local.
                    self.value = snapshot
                    self.callbackHandler(snapshot)
                }
                mqtt.onState = { state in
                    NotificationCenter.default.post(name: MQTTSettings.stateChanged, object: state)
                }
                self.mqtt = mqtt
            }
            self.mqtt?.start()
        }
    }

    public override func pause() {
        super.pause()
        self.disconnect()
    }

    public override func stop() {
        super.stop()
        self.disconnect()
    }

    public override func terminate() {
        self.stop()
    }

    private func disconnect() {
        let disconnect = { [weak self] in
            self?.mqtt?.stop()
            self?.mqtt = nil
            self?.value = nil
        }
        if Thread.isMainThread { disconnect() }
        else { DispatchQueue.main.sync(execute: disconnect) }
    }
}
