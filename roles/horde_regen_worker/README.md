# AI Horde regen Worker

Deploys all the necessary components to turn a debian-based linux server into an AI Horde worker instance running via systemd

The default variables contain all the arguments required for a worker's [bridgeData](https://github.com/Haidra-Org/horde-worker-regen/blob/main/bridgeData_template.yaml) so you can provide any of them in your role variables to override the defaults from the template.

In addition you can pass the following 2 vars

* `worker_username`: The Worker service will run in userspace using systemd, this is the username under which the service should run. It doesn't have to be be root or have sudo access.
* `worker_environment`: Any environment args you might need to pass to the worker process such as `ROCR_VISIBLE_DEVICES=0` etc

# Instructions

1. Prepare a debian-based linux server with a GPU.
1. Make a playbook to call the relevant roles. An example `examples/regen_worker.yml` playbook has been provided.
1. Create an ansible inventory `inventory.yml` with your host address and worker variables. An example has been provided in `examples/inventory.yml` which you can copy and modify
1. Run the ansible-playbook

```bash
ansible-playbook regen_worker.yml -i inventory.yml
```


