# nfsen-ng-docker

Docker setup for running nfsen-ng (Netflow visualizer) and nfdump (Netflow/Sflow collector) together with support for mutiple sources.

## Installation

1. git pull https://github.com/dircr/nfsen-ng-docker.git
2. verify ports and paths in docker-compose.yaml

## Usage

1. fill source.conf
    - csv style file with format : "device;port;proto"
    - where:
        - device is a display name like 'my-awesome-router'
        - port is a uniq value in-between 9000-9099
        - proto is sflow or nflow depending on your device capabilities)
2. docker-compose up -d
3. browse to http://localhost:81

=> additonally, you may add/remove lines in sources.conf... you need then to restart the stack by issuing 'docker-compose restart'

## Tested with:
- Arista EOS 4.23.3M (in Jan 2021)
- Ubiquiti EdgeRouter™ X

## An issue ?

1. clone
2. correct
3. share
