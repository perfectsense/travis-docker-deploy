#!/usr/bin/ruby -w

require 'fileutils'

def require_env_var(var_name)
  if ENV[var_name] == nil or ENV[var_name].empty?
    raise ArgumentError, "Required Environmental Variable [ #{var_name} ] is not found."
  end
  return ENV[var_name]
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

  if !File.exist?("#{docker_dir}/docker_metadata.sh")
    raise ArgumentError, "[ docker_metadata.sh ] file not found in [ #{docker_dir} ]"
  end
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

def push_image(docker_host, docker_repo_prefix, docker_image_name, user, password, tag, latest)
  docker_image = "#{docker_host}/#{docker_repo_prefix}/#{docker_image_name}:#{tag}"

  system("docker login #{docker_host} -u #{user} -p #{password}")
  system("docker push #{docker_image}")
  if $? != 0
    raise ArgumentError, 'Failed to push container'
  end

  if latest
    system("docker tag #{docker_image} #{docker_host}/#{docker_repo_prefix}/#{docker_image_name}:latest")
    system("docker push #{docker_host}/#{docker_repo_prefix}/#{docker_image_name}:latest")
  end
  return docker_image
end

def calculate_repo_name(full_repo)
  if full_repo.match(/(.*)@(.*):(.*)\/(.*)\.git/)
    full_repo.gsub(/(.*)@(.*):(.*)\//, '').gsub(/\.git/, '')
  elsif full_repo.match(/http(s):\/\/(.*)\/(.*)\/(.*)\.git/)
    full_repo.gsub(/http(s):\/\/(.*)\/(.*)\//, '').gsub(/\.git/, '')
  end
end

def copy_local_defaults_to_remote(defaults_repo_name, defaults_label)
  remote_defaults_dir = "#{defaults_repo_name}/#{defaults_label}"
  if Dir.exist?(remote_defaults_dir)
    FileUtils.remove_dir(remote_defaults_dir, true)
  end

  FileUtils.mkdir(remote_defaults_dir)
  FileUtils.cp_r 'defaults/.', remote_defaults_dir, :verbose => true
end

def update_remote_defaults(defaults_label, container, docker_tag)
  defaults_repo = require_env_var('DEFAULTS_REPOSITORY')
  defaults_repo_name = calculate_repo_name(defaults_repo)

  system("git clone #{defaults_repo}")
  copy_local_defaults_to_remote(defaults_repo_name, defaults_label)

  Dir.chdir(defaults_repo_name)
  system("git add #{defaults_label}; git commit -m \"Updating [ #{defaults_label} ] defaults. Triggered by Docker build [ #{docker_tag} ]\"; git push origin master")

  git_tag = "#{container}/#{docker_tag}"
  existing_tag = %x[git tag -l #{git_tag}]
  if existing_tag != nil
    puts "Git tag [ #{git_tag} ] exists! Overwriting."
    system("git tag -d #{git_tag}; git push origin :refs/tags/#{git_tag}")
  end

  system("git tag -a #{git_tag} -m \"Updating [ #{defaults_label} ] defaults. Triggered by Docker build [ #{docker_tag} ]\"; git push origin #{git_tag}")
end

build_dir = Dir.pwd
check_preconditions(build_dir)
docker_dir = "#{build_dir}/docker"
metadata = extract_metadata("#{docker_dir}/docker_metadata.sh")
tag_type = calculate_tag_type

latest = false
if tag_type == 'pull_request'
  docker_tag = ENV['TRAVIS_PULL_REQUEST_BRANCH'].gsub('/', '-')
elsif tag_type == 'increment_patch'
  docker_tag = metadata['DOCKER_MINOR_VERSION'] + '.' + ENV['TRAVIS_BUILD_NUMBER']
  latest = true
end

for container_json in Dir["#{docker_dir}/*.json"]
  puts container_json
  container = container_json.split('/')[-1].split('.')[0]
  puts "Building [ #{container} ] Docker Image"

  Dir.chdir(docker_dir)
  system(%W[
    ./build.sh
    -t #{docker_tag}
    -u #{ENV['DOCKER_BUILDER_USER']}
    -p #{ENV['DOCKER_BUILDER_PASSWORD']}
    -n -a
    #{container}
  ].join(' '))
  Dir.chdir(build_dir)

  push_image(
    metadata['DOCKER_REGISTRY_HOST'],
    metadata['DOCKER_REPOSITORY_PREFIX'],
    container,
    ENV['DOCKER_BUILDER_USER'],
    ENV['DOCKER_BUILDER_PASSWORD'],
    docker_tag,
    latest)

  if Dir.exist?("#{build_dir}/defaults") and ENV['DEFAULTS_LABEL'] != nil
    update_remote_defaults(ENV['DEFAULTS_LABEL'], container, docker_tag)
  else
    puts "Cannot push to Defaults Repo. Defaults Directory or Label does not exist!"
  end
end

