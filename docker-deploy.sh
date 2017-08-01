#!/bin/bash

function build_container() {

    if [[ -z $1 ]]; then
       echo "DOCKER_TAG is required to build a container"
       exit 1
    fi

    export DOCKER_TAG=$1

    echo "travis_fold:start:calculate-base-image"
    BASE_IMAGE=""
    base_registry_host=`cat DOCKER_METADATA | grep "BASE_IMAGE_REGISTRY_HOST" | awk '{print $2}'`
    base_repository=`cat DOCKER_METADATA | grep "BASE_IMAGE_REPOSITORY" | awk '{print $2}'`
    base_minor_version=`cat DOCKER_METADATA | grep "BASE_IMAGE_MINOR_VERSION" | awk '{print $2}'`
    if [[ ! -z $base_registry_host &&
        ! -z $base_repository &&
        ! -z $base_minor_version ]]; then

        tag_catalog_url=`echo $base_repository | awk -v host=$base_registry_host -F'/' '{print "https://"host"/v2/"$1"/"$2"/tags/list"}'`

        echo "Fetching base image tags at: [ $tag_catalog_url ]"
        minor_version_tags=`curl -u $DOCKER_BUILDER_USER:$DOCKER_BUILDER_PASSWORD $tag_catalog_url | jq -r '.tags[]' | grep $base_minor_version || echo ""`
        if [[ ! -z $minor_version_tags ]]; then
            echo "Tags from [ $base_registry_host/$base_repository ] that match desired minor version [ $base_minor_version ]"
            echo $minor_version_tags
            base_patch_version=-1

            for tag in $minor_version_tags; do
                tag_patch_version=${tag/$base_minor_version\./""}
                if (( $tag_patch_version > $base_patch_version )); then
                    base_patch_version=$tag_patch_version
                fi
            done

            if (( $base_patch_version >= 0 )); then
                BASE_IMAGE=$base_registry_host/$base_repository:$base_minor_version.$tag_patch_version
            else
                echo "No Matching Base Image Patch Version was found!"
            fi
        else
            echo "No Matching Base Image Minor Versions were found!"
        fi
    else
        echo "Base Image Registry host, repository and/or Minor Version could not be found!"
    fi

    if [[ ! -z $BASE_IMAGE ]]; then
       echo "Using Base Image [ $BASE_IMAGE ]"
       export BASE_IMAGE
    else
       echo "No Base Image could be found!"
       exit 1;
    fi
    echo "travis_fold:end:calculate-base-image"

    echo "travis_fold:start:install-packer"
    packer_dir=$BUILD_DIRECTORY/tmp-packer
    if [[ ! -d $packer_dir ]]; then
        mkdir -p $packer_dir && cd $packer_dir
        wget https://releases.hashicorp.com/packer/1.0.0/packer_1.0.0_linux_amd64.zip
        unzip packer_1.0.0_linux_amd64.zip
        cd $BUILD_DIRECTORY
    else
       echo "Packer is already installed. Skipping..."
    fi
    echo "travis_fold:end:install-packer"

    echo "travis_fold:start:berks-vendor"
    if [[ -d $BUILD_DIRECTORY/vendor/cookbooks ]]; then
        rm -rf $BUILD_DIRECTORY/vendor/cookbooks
    fi
    berks vendor $BUILD_DIRECTORY/vendor/cookbooks
    echo "travis_fold:end:berks-vendor"

    docker login $base_registry_host -u $DOCKER_BUILDER_USER -p $DOCKER_BUILDER_PASSWORD
    docker login $DOCKER_REGISTRY_HOST -u $DOCKER_BUILDER_USER -p $DOCKER_BUILDER_PASSWORD

    echo "travis_fold:start:packer-build"
    $packer_dir/packer build packer.json
    echo "travis_fold:end:packer-build"

    echo "travis_fold:start:docker-push"
    echo "Tagging : [$FULL_DOCKER_REPOSITORY:$DOCKER_TAG]"
    docker push $FULL_DOCKER_REPOSITORY:$DOCKER_TAG

    if [[ "$2" == "latest" ]]; then
        echo "Tagging : [$FULL_DOCKER_REPOSITORY:latest]"
        docker tag $FULL_DOCKER_REPOSITORY:$DOCKER_TAG $FULL_DOCKER_REPOSITORY:latest
        docker push $FULL_DOCKER_REPOSITORY:latest
    fi
    echo "travis_fold:end:docker-push"
}

function calculate_tags_and_build_container() {

    echo "Current Major Version is $major_version"
    if [[ "$DOCKER_GIT_TAG_ENABLED" == "true" ]]; then

        echo "Using Git Tags to increment version"

        git fetch --tags
        git_tags=`git tag -l --sort=v:refname | grep $major_version || echo ""`
        current_minor_version=""
        for git_tag in $git_tags; do
            current_minor_version=$git_tag
        done

        if [[ ! -z $current_minor_version ]]; then
            echo "Current Minor Version is $current_minor_version"
            version_parts=( ${current_minor_version//./ } )
            version_parts[1]=$(( ${version_parts[1]}+1 ))
            new_minor_version=${version_parts[0]}.${version_parts[1]}
        else
            echo "No Current Minor Version"
            new_minor_version=$major_version"0"
        fi
    else

        echo "Using Docker Tags to increment version"
        tag_catalog_url=`echo $DOCKER_REPOSITORY | awk -v host=$DOCKER_REGISTRY_HOST -F'/' '{print "https://"host"/v2/"$1"/"$2"/tags/list"}'`

        echo "Fetching base image tags at: [ $tag_catalog_url ]"
        major_version_tags=`curl -u $DOCKER_BUILDER_USER:$DOCKER_BUILDER_PASSWORD $tag_catalog_url | jq -r '.tags[]' | grep $major_version || echo ""`
        if [[ ! -z $major_version_tags ]]; then
            echo "Tags from [ $DOCKER_REGISTRY_HOST/$DOCKER_REPOSITORY ] that match desired major version [ $major_version ]"
            echo $major_version_tags
            minor_version=-1

            for tag in $major_version_tags; do
                echo $tag
                tag_minor_version=$(echo $tag | awk -F'.' '{print $2}')
                echo $tag_minor_version
                if (( $tag_minor_version > $minor_version )); then
                    minor_version=$tag_minor_version
                fi
            done
            if (( $minor_version > -1 )); then
               minor_version=$((minor_version+1))
            else
               $minor_version=0
            fi
            new_minor_version=$major_version$minor_version
        else
            echo "No Major Version tags found!"
            new_minor_version=$major_version"0"
        fi
    fi

    echo "New Minor Version is $new_minor_version"
    build_container $new_minor_version.$TRAVIS_BUILD_NUMBER "latest"

    if [[ "$DOCKER_GIT_TAG_ENABLED" == "true" ]]; then
        git tag -a $new_minor_version -m "Tag for version $new_minor_version"
        git push origin tag $new_minor_version -f
    fi
}

echo "Installing Berkshelf"
gem install berkshelf

echo "Current Working Directory is [ $(pwd) ]"
export BUILD_DIRECTORY=$(pwd)

set -e -u

major_version=`cat DOCKER_METADATA | grep "MAJOR_VERSION" | awk '{print $2}'`
export DOCKER_REGISTRY_HOST=`cat DOCKER_METADATA | grep "DOCKER_REGISTRY_HOST" | awk '{print $2}'`
export DOCKER_REPOSITORY=`cat DOCKER_METADATA | grep "DOCKER_REPOSITORY" | awk '{print $2}'`
export DOCKER_GIT_TAG_ENABLED=`cat DOCKER_METADATA | grep "DOCKER_GIT_TAG_ENABLED" | awk '{print $2}'`
if [[ -z $DOCKER_REGISTRY_HOST ||
    -z $DOCKER_REPOSITORY ]]; then
   echo "Docker Registry Host and Repository are required!"
   exit 1
fi

export FULL_DOCKER_REPOSITORY=$DOCKER_REGISTRY_HOST/$DOCKER_REPOSITORY

if [[ "$TRAVIS_PULL_REQUEST" == "false" &&
    "$TRAVIS_EVENT_TYPE" == "push" ]]; then    

    environments_enabled=`cat DOCKER_METADATA | grep "ENVIRONMENTS_ENABLED" | awk '{print $2}'`
    if [[ $environments_enabled == "true" ]]; then

        echo "Building Containers for all environments in [$TRAVIS_BUILD_DIR/ops/chef/environments]"

        for environment_file in $(ls $TRAVIS_BUILD_DIR/ops/chef/environments); do
            export ENVIRONMENT=$(echo $environment_file | awk -F'.' '{print $1}')
            if [[ $ENVIRONMENT == "production" ]]; then
                calculate_tags_and_build_container
            elif [[ $ENVIRONMENT == "vagrant" ]]; then
               echo "Skipping Vagrant Environment..."
            else
               build_container $ENVIRONMENT $ENVIRONMENT
            fi
        done

    else
        calculate_tags_and_build_container
    fi

elif [[ "$TRAVIS_PULL_REQUEST" != "false" ]]; then
    build_container `echo $TRAVIS_PULL_REQUEST_BRANCH | awk '{ gsub("/", "-"); print }'`

elif [[ "$TRAVIS_EVENT_TYPE" == "api" &&
    "$DOCKER_GIT_TAG_ENABLED" ]]; then

    echo "Triggered by API. Looping through known tags and updating..."
    git fetch --tags
    git_tags=`git tag -l --sort=v:refname || echo ""`
    for git_tag in $git_tags; do
        echo "Resetting to Git Tag [ $git_tag ]"
        git reset --hard $git_tag
        build_container $git_tag.$TRAVIS_BUILD_NUMBER
    done

else
    echo "Not a recognized Travis Trigger!"
    exit 1
fi

