#!/bin/bash

function build_container() {

    echo "travis_fold:start:install-packer"
    packer_dir=$BUILD_DIRECTORY/tmp-packer
    if [[ ! -d $packer_dir ]]; then
        mkdir -p $packer_dir && cd $packer_dir
        wget https://releases.hashicorp.com/packer/1.0.0/packer_1.0.0_linux_amd64.zip
        unzip packer_1.0.0_linux_amd64.zip
        export PACKER=$BUILD_DIRECTORY/tmp-packer/packer 
        cd $BUILD_DIRECTORY
    else
       echo "Packer is already installed. Skipping..."
    fi
    echo "travis_fold:end:install-packer"

    docker login $BASE_IMAGE_REGISTRY_HOST -u $DOCKER_BUILDER_USER -p $DOCKER_BUILDER_PASSWORD
    docker login $DOCKER_REGISTRY_HOST -u $DOCKER_BUILDER_USER -p $DOCKER_BUILDER_PASSWORD

    if [[ "$docker_tag_type" == "pull_request" ]]; then
        ./build.sh -t $(echo $TRAVIS_PULL_REQUEST_BRANCH | awk '{ gsub("/", "-"); print }') -b $BASE_IMAGE_TAG $CONTAINER

    elif [[ "$docker_tag_type" == "environment" ]]; then
        ./build.sh -t $ENVIRONMENT -e $ENVIRONMENT -b $BASE_IMAGE_TAG $CONTAINER
        
    elif [[ "$docker_tag_type" == "increment_minor_version" ||
        "$docker_tag_type" == "increment_patch_version"  ]]; then

        echo "Using Docker Tags to increment version"
        tag_catalog_url=`echo $DOCKER_REPOSITORY | awk -v host=$DOCKER_REGISTRY_HOST -F'/' '{print "https://"host"/v2/"$1"/"$2"/tags/list"}'`

        echo "Fetching base image tags at: [ $tag_catalog_url ]"
        major_version_tags=`curl -u $DOCKER_BUILDER_USER:$DOCKER_BUILDER_PASSWORD $tag_catalog_url | jq -r '.tags[]' | grep $MAJOR_VERSION || echo ""`
        if [[ ! -z $major_version_tags ]]; then
            echo "Tags from [ $DOCKER_REGISTRY_HOST/$DOCKER_REPOSITORY ] that match desired major version [ $MAJOR_VERSION ]"
            echo $major_version_tags
            minor_version=-1

            for tag in $major_version_tags; do
                tag_minor_version=$(echo $tag | awk -F'.' '{print $2}')
                if (( $tag_minor_version > $minor_version )); then
                    minor_version=$tag_minor_version
                fi
            done

            if (( $minor_version > -1 )); then
               if [[ "$docker_tag_type" == "increment_minor_version" ]]; then
                   echo "Incrementing minor version"
                   minor_version=$((minor_version+1))
               fi
            else
               $minor_version=0
            fi
            new_minor_version=$MAJOR_VERSION$minor_version
        else
            echo "No Major Version tags found!"
            new_minor_version=$MAJOR_VERSION"0"
        fi

        echo "Calculated Minor Version is $new_minor_version"

        if [[ -z $ENVIRONMENT ]]; then
            ./build.sh -t "$new_minor_version.$TRAVIS_BUILD_NUMBER" -b $BASE_IMAGE_TAG $CONTAINER
        else
            ./build.sh -t "$new_minor_version.$TRAVIS_BUILD_NUMBER" -e $ENVIRONMENT -b $BASE_IMAGE_TAG $CONTAINER
        fi

    else
        echo "Could not calculate docker tag type!"
        continue
    fi
}


echo "Current Working Directory is [ $(pwd) ]"
export BUILD_DIRECTORY=$(pwd)
export CHEF_DIRECTORY="$BUILD_DIRECTORY/../chef"

for CONTAINER in *; do
    [[ -d "$CONTAINER" ]] || continue

    unset DOCKER_REGISTRY_HOST
    unset DOCKER_REPOSITORY
    unset MAJOR_VERSION
    unset BASE_IMAGE_REGISTRY_HOST
    unset BASE_IMAGE_REPOSITORY
    unset BASE_IMAGE_MINOR_VERSION
    unset ENVIRONMENTS_ENABLED
    unset FULL_DOCKER_REPOSITORY
    unset BASE_IMAGE
    unset BASE_IMAGE_TAG
    unset ENVIRONMENT
    unset docker_tag_type
    

    echo "Analyzing [ $CONTAINER ] for build"

    set -e -u
    
    if [[ ! -f $CONTAINER/docker_metadata.sh ]]; then
        echo "docker_metadata file not found!"
        continue
    fi
    
    . $CONTAINER/docker_metadata.sh
    
    if [[ -z $DOCKER_REGISTRY_HOST ||
        -z $DOCKER_REPOSITORY ]]; then
       echo "Docker Registry Host and Repository are required!"
       continue
    fi
    
    export FULL_DOCKER_REPOSITORY=$DOCKER_REGISTRY_HOST/$DOCKER_REPOSITORY
    
    echo "travis_fold:start:calculate-base-image"
    BASE_IMAGE=""
    if [[ ! -z $BASE_IMAGE_REGISTRY_HOST &&
        ! -z $BASE_IMAGE_REPOSITORY &&
        ! -z $BASE_IMAGE_MINOR_VERSION ]]; then
    
        tag_catalog_url=`echo $BASE_IMAGE_REPOSITORY | awk -v host=$BASE_IMAGE_REGISTRY_HOST -F'/' '{print "https://"host"/v2/"$1"/"$2"/tags/list"}'`
    
        echo "Fetching base image tags at: [ $tag_catalog_url ]"
        minor_version_tags=`curl -u $DOCKER_BUILDER_USER:$DOCKER_BUILDER_PASSWORD $tag_catalog_url | jq -r '.tags[]' | grep $BASE_IMAGE_MINOR_VERSION || echo ""`
        if [[ ! -z $minor_version_tags ]]; then
            echo "Tags from [ $BASE_IMAGE_REGISTRY_HOST/$BASE_IMAGE_REPOSITORY ] that match desired minor version [ $BASE_IMAGE_MINOR_VERSION ]"
            echo $minor_version_tags
            base_patch_version=-1
    
            for tag in $minor_version_tags; do
                tag_patch_version=${tag/$BASE_IMAGE_MINOR_VERSION\./""}
                if (( $tag_patch_version > $base_patch_version )); then
                    base_patch_version=$tag_patch_version
                fi
            done
    
            if (( $base_patch_version >= 0 )); then
                export BASE_IMAGE_TAG="$BASE_IMAGE_MINOR_VERSION.$tag_patch_version"
                BASE_IMAGE="$BASE_IMAGE_REGISTRY_HOST/$BASE_IMAGE_REPOSITORY:$BASE_IMAGE_TAG"
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
       continue
    fi
    echo "travis_fold:end:calculate-base-image"

    echo "travis_fold:start:calculate-docker-tag-type"
    if [[ "$TRAVIS_PULL_REQUEST" == "false" &&
        "$TRAVIS_EVENT_TYPE" == "push" ]]; then    
    
        if [[ ${ENVIRONMENTS_ENABLED+x} &&
            $ENVIRONMENTS_ENABLED == "true" ]]; then
            docker_tag_type="environments"
        else
            docker_tag_type="increment_minor_version"
        fi

    elif [[ "$TRAVIS_PULL_REQUEST" != "false" ]]; then
        docker_tag_type="pull_request"
    elif [[ "$TRAVIS_EVENT_TYPE" == "api" ]]; then
        docker_tag_type="increment_patch_version"
    fi

    export $docker_tag_type

    cd $BUILD_DIRECTORY

    if [[ $docker_tag_type == "environments" ]]; then
        echo "Building Containers for all environments in [$CHEF_DIRECTORY/environments]"
        cd $CHEF_DIRECTORY/environments
    
        for environment_file in *.json; do
            export ENVIRONMENT=$(echo $environment_file | awk -F'.' '{print $1}')
            if [[ $ENVIRONMENT == "production" ]]; then
                export docker_tag_type="increment_minor_version"
                cd $BUILD_DIRECTORY
                build_container
            elif [[ $ENVIRONMENT == "vagrant" ]]; then
               echo "Skipping Vagrant Environment..."
            else
               export docker_tag_type="environment"
               cd $BUILD_DIRECTORY
               echo "Environment Tag [ $ENVIRONMENT ]"
               build_container
            fi
        done
    else
        build_container
    fi
done

