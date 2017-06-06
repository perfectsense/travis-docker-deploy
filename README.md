# Travis Docker Build Script

This script is used by [Travis CI](https://travis-ci.com/) to continuously build docker containers and push them to the appropriate docker repo.

It should only build containers for pushes to the master branch and open Pull Requests to the Master branch.  The Master branch will create a new git tag that will use the major version in the `DOCKER_METADATA` file combined with the minor version.  The minor version increments with every new push to the master branch.  It will also create a Docker tag with the Major version, minor version, and travis build number, i.e., v1.2.123.

If the build is triggered from a Pull Request, the Docker tag will be the name of the branch from which the PR originated from, with slashes replaced with dashes:
```
feature/new/functionality
```
becomes
```
feature-new-functionality
```
This is due to `/` being an illegal character in docker tags.

## Usage

Your .travis.yml should look something like this:

```yaml
dist: trusty
language: ruby
rvm: 2.3.4

branches:
  only:
  - master

sudo: required

services:
  - docker

before_script:
  - gem install berkshelf

script:
  - git clone https://github.com/perfectsense/travis-docker-deploy.git && travis-docker-deploy/docker-deploy.sh
```

You should also have a file called `DOCKER_METADATA` at the root of the repo.  It should look similar to this:
```
DOCKER_REGISTRY_HOST my.registry.host.com
DOCKER_REPOSITORY my-docker/repository
MAJOR_VERSION v0.

BASE_IMAGE_REGISTRY_HOST my.base.images.host.com
BASE_IMAGE_REPOSITORY base=images/repository
BASE_IMAGE_MINOR_VERSION v0.7
```

## Travis Environmental Variables

If the docker repository requires a login, these should be set.
```
DOCKER_BUILDER_USER
DOCKER_BUILDER_PASSWORD
```

