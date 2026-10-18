#cloud-config
# Installation automatique d'Ubuntu Server (autoinstall) - genere par create_vms.ps1
autoinstall:
  version: 1
  locale: fr_FR.UTF-8
  keyboard:
    layout: {{KEYBOARD}}
{{NETWORK}}
  storage:
    layout:
      name: lvm
      sizing-policy: all
      match:
        size: largest
  ssh:
    install-server: true
    allow-pw: true
  late-commands:
    # demons Hyper-V (hv_kvp) : sans eux, Hyper-V ne voit pas l'adresse IP de la VM ; echec tolere
    - curtin in-target --target=/target -- apt-get install -y linux-cloud-tools-virtual || true
  shutdown: poweroff
  user-data:
    hostname: {{NAME}}
    timezone: Europe/Paris
    ssh_pwauth: true
    users:
      - name: {{USER}}
        groups: [sudo]
        shell: /bin/bash
        lock_passwd: false
        {{SSHKEYS}}
    chpasswd:
      expire: false
      users:
        - {name: {{USER}}, password: "{{PASSWORD}}", type: text}
    write_files:
      - path: /etc/hosts
        append: true
        content: |
{{HOSTS}}
    runcmd:
      - systemctl enable --now ssh
