import UIKit

final class GamepadViewController: UIViewController {
    private let pad = GamepadView()
    private let client = GamepadClient()
    private let serverButton = UIButton(type: .system)
    private var active = false
    private var editingServer = false
    private var serverAddress: String {
        get { UserDefaults.standard.string(forKey: "serverAddress") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serverAddress") }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func loadView() { view = pad }

    override func viewDidLoad() {
        super.viewDidLoad()
        serverButton.setTitle("Set server", for: .normal)
        serverButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        serverButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        serverButton.accessibilityIdentifier = "serverButton"
        serverButton.addTarget(self, action: #selector(editServer), for: .touchUpInside)
        serverButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(serverButton)
        NSLayoutConstraint.activate([
            serverButton.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            serverButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            serverButton.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, multiplier: 0.55),
            serverButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        pad.onChange = { [weak self] state in self?.client.update(state) }
        client.onReset = { [weak self] in self?.pad.reset() }
        client.onStatus = { [weak self] status, connected in
            guard let self else { return }
            self.pad.enabled = connected && self.active && !self.editingServer
            UIApplication.shared.isIdleTimerDisabled = self.pad.enabled
            self.serverButton.setTitle("\(status) · Server", for: .normal)
            self.serverButton.tintColor = connected ? .systemGreen : .systemOrange
            self.serverButton.accessibilityLabel = "\(status). Change server"
        }
    }

    func setActive(_ active: Bool) {
        self.active = active
        if active && !editingServer {
            if let url = ServerAddress.url(from: serverAddress) { client.start(url) }
            else { editServer() }
        } else if !active { client.stop() }
    }

    @objc private func editServer() {
        guard presentedViewController == nil else { return }
        editingServer = true
        client.stop()
        let alert = UIAlertController(title: "joystream", message:
            "Enter the address printed by your joystream server. Use the same Wi-Fi or a Tailscale IP.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "192.168.1.10:8000"
            field.text = self.serverAddress
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
            field.accessibilityIdentifier = "serverAddress"
            field.addTarget(self, action: #selector(self.addressChanged(_:)), for: .editingChanged)
        }
        let connect = UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text,
                  ServerAddress.url(from: text) != nil else { return }
            self.serverAddress = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.editingServer = false
            if self.active, let url = ServerAddress.url(from: self.serverAddress) { self.client.start(url) }
        }
        connect.isEnabled = ServerAddress.url(from: serverAddress) != nil
        alert.addAction(connect)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            guard let self else { return }
            self.editingServer = false
            if self.active, let url = ServerAddress.url(from: self.serverAddress) { self.client.start(url) }
        })
        present(alert, animated: true)
    }

    @objc private func addressChanged(_ field: UITextField) {
        (presentedViewController as? UIAlertController)?.actions.first?.isEnabled =
            ServerAddress.url(from: field.text ?? "") != nil
    }
}
