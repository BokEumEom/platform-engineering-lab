# Environment

Use this chapter to prepare the local reference environment before changing workloads or platform components.

## Baseline used by the lab

The original walkthrough was developed on Windows with Ubuntu 24.04 on WSL2, Docker Desktop, and a three-node local Kubernetes cluster. The exact host resources may differ, but the cluster must have enough capacity to run the platform and observability stack.

A three-node layout is useful because it makes scheduling, disruption, topology spread, cordon/drain, and PDB behavior observable.

## Docker Desktop and WSL2

Enable the WSL2 engine and the Ubuntu integration in Docker Desktop. From WSL, verify Docker access:

~~~bash
docker version
~~~

If access to /var/run/docker.sock is denied, inspect the socket and group membership before installing another Docker daemon inside WSL.

~~~bash
ls -l /var/run/docker.sock
id
getent group docker
~~~

If needed, add the current user to the docker group and start a new group session.

## Kubernetes CLI

Verify the client, server, and nodes:

~~~bash
kubectl version
kubectl get nodes -o wide
~~~

All nodes should be Ready before moving on.

Remember:

- kubectl get reads actual cluster state.
- kubectl apply submits desired state.
- a successful apply does not prove application traffic or health.

## Helm

Helm is used for packaged Kubernetes components such as Envoy Gateway and observability charts.

~~~bash
helm version
~~~

Install Helm using the official package instructions for the host distribution when it is missing. Avoid copying an old installation command solely because it appeared in a historical walkthrough.

## Repository

~~~bash
git clone git@github.com:BokEumEom/platform-engineering-lab.git
cd platform-engineering-lab
~~~

Continue with [Kubernetes basics](kubernetes-basics.md).
