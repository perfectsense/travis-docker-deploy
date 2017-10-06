#!/usr/bin/ruby -w

require 'fileutils'

def require_env_var(var_name)
  if ENV[var_name] == nil or ENV[var_name].empty?
    raise ArgumentError, "Required Environmental Variable [ #{var_name} ] is not found."
  end
  return ENV[var_name]
end

def install_packer(build_dir)

  if !Dir.exist?("#{build_dir}/tmp-packer")
    puts 'travis_fold:start:install-packer'
      FileUtils.mkdir_p("#{build_dir}/tmp-packer")
      Dir.chdir("#{build_dir}/tmp-packer")
      system('wget https://releases.hashicorp.com/packer/1.0.0/packer_1.0.0_linux_amd64.zip; unzip packer_1.0.0_linux_amd64.zip')
      Dir.chdir(build_dir)
    puts 'travis_fold:end:install-packer'
  end

  return "#{build_dir}/tmp-packer/packer"
end

def calculate_tag_type
  if ENV['TRAVIS_EVENT_TYPE'] == 'pull_request'
    tag_type = 'pull_request'
    puts "Docker Tag will be Pull Request Branch Name"
  else 
    tag_type = 'increment_patch'
    puts "Docker Tag will increment Patch Version"
  end

  return tag_type
end

def extract_metadata(file)

  metadata = Hash.new

  File.foreach(file) do |line|
    if line.match(/export (.)*=\"(.)*\"/)
      key_and_value = line.gsub('export ', '').gsub('\"', '').strip.split("=")
      metadata[key_and_value[0]] = key_and_value[1]
    end
  end

  return metadata
end

def push_container(docker_host, docker_repo, user, password, tag, latest)
  docker_image = "#{docker_host}/#{docker_repo}:#{tag}"

  system("docker login #{docker_host} -u #{user} -p #{password}")
  system("docker push #{docker_image}")
  if $? != 0
    raise ArgumentError, 'Failed to push container'
  end

  if latest
    system("docker tag #{docker_image} #{docker_host}/#{docker_repo}:latest")
    system("docker push #{docker_host}/#{docker_repo}:latest")
  end
end

def build_container(container, docker_dir, packer_exec)

  puts "Analyzing [ #{container} ] for build"
  container_dir = "#{docker_dir}/#{container}"
  metadata = extract_metadata("#{container_dir}/docker_metadata.sh")
  tag_type = calculate_tag_type

  latest = false
  if tag_type == 'pull_request'
    docker_tag = ENV['TRAVIS_PULL_REQUEST_BRANCH'].gsub('/', '-')
  elsif tag_type == 'increment_patch'
    docker_tag = metadata['DOCKER_MINOR_VERSION'] + '.' + ENV['TRAVIS_BUILD_NUMBER']
    latest = true
  end

  Dir.chdir(docker_dir)

  system(%W[
    #{docker_dir}/build.sh
    -t #{docker_tag}
    -u #{ENV['DOCKER_BUILDER_USER']}
    -p #{ENV['DOCKER_BUILDER_PASSWORD']}
    -n -a
    #{container}
  ].join(' '))

  push_container(
    metadata['DOCKER_REGISTRY_HOST'],
    metadata['DOCKER_REPOSITORY'],
    ENV['DOCKER_BUILDER_USER'],
    ENV['DOCKER_BUILDER_PASSWORD'],
    docker_tag,
    latest)
end

def check_preconditions(build_dir)

  docker_dir = "#{build_dir}/docker"
  if !Dir.exist?(docker_dir)
    raise ArgumentError, 'Docker directory does not exist!'
  end

  if !File.exist?("#{docker_dir}/build.sh")
    raise ArgumentError, 'Docker build script does not exist!'
  end

  require_env_var('DOCKER_BUILDER_USER')
  require_env_var('DOCKER_BUILDER_PASSWORD')

  container = require_env_var('CONTAINER')
  if !Dir.exist?("#{docker_dir}/#{container}")
    raise ArgumentError, 'Container directory does not exist!'
  end

  if !File.exist?("#{docker_dir}/#{container}/docker_metadata.sh")
    raise ArgumentError, "[ docker_metadata.sh ] file not found for [ #{container} ] container"
  end

  if !File.exist?("#{docker_dir}/#{container}/packer.json")
    raise ArgumentError, "[ packer.json ] file not found for [ #{container} ] container"
  end
end  

def build

  build_dir = Dir.pwd
  check_preconditions(build_dir)

  build_container(
    ENV['CONTAINER'],
    "#{build_dir}/docker",
    install_packer(build_dir))

end

build

