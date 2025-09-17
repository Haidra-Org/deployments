# Haidra Deployments

Code for deploying the various Haidra services

# Usage

These deployments are all using [ansible](https://www.ansible.com/) the use of which is beyond the scope of this readme. 

You can install ansible on Linux using pip. It doesn't work on Windows.

```bash
python -m pip install ansible
```

Make sure your local account can ssh to the various linux machines using ssh and public key authentication using an ssh-agent.

Make sure your remote account has sudo access. If it require a sudo password, make sure you append `-K` to all `ansible-playbook` commands you see in the READMEs.

Make sure you download this collection using ansible-galaxy. An example requirements.yml file has been provided.

```bash
wget https://raw.githubusercontent.com/Haidra-Org/deployments/main/examples/requirements.yml
ansible-galaxy collection install -r requirements.yml
```

# Included Roles

Each role within provides its own readme with instructions. 

Typically you just need to adjust an inventory with your hostnames and addresses and then adjust one of the examples provided.

Or you can make your own global `site.yml` with all your configuration for the various Haidra services.


* [artbot](roles/artbot/README.md)
* [artbot_revproxy](roles/artbot_revproxy/README.md)
* [horde_regen_worker](roles/horde_regen_worker/README.md)
* [amd_gpu_drivers](roles/amd_gpu_drivers/README.md)
