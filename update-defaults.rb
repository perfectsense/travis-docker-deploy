#!/usr/bin/ruby -w

require 'fileutils'

def require_env_var(var_name, err_msg="Exiting")
  if ENV[var_name] == nil or ENV[var_name].empty?
    puts "Required Variable [ #{var_name} ] is not found."
    puts err_msg
    exit(false)
  end
  return ENV[var_name]
end

def calculate_repo_name(full_repo)
  if full_repo.match(/(.*)@(.*):(.*)\/(.*)\.git/)
    full_repo.gsub(/(.*)@(.*):(.*)\//, '').gsub(/\.git/, '')
  elsif full_repo.match(/http(s):\/\/(.*)\/(.*)\/(.*)\.git/)
    full_repo.gsub(/http(s):\/\/(.*)\/(.*)\//, '').gsub(/\.git/, '')
  end
end

def copy_local_defaults_to_remote(repo_name, container)
  
  remote_defaults_dir = "#{repo_name}/#{container}"
  if Dir.exist?(remote_defaults_dir)
    FileUtils.remove_dir(remote_defaults_dir, true)
  end
  
  FileUtils.mkdir(remote_defaults_dir)
  FileUtils.cp_r 'defaults/.', remote_defaults_dir, :verbose => true
end

def update_remote_defaults
  if !Dir.exist?('defaults')
    puts 'Cannot find [ defaults ] directory. Exiting.'
    exit(false)
  end
  
  container = require_env_var("CONTAINER")
  defaults_repo = require_env_var("DEFAULTS_REPOSITORY")
  docker_tag = require_env_var("DOCKER_TAG")

  defaults_repo_name = calculate_repo_name(defaults_repo)

  system("git clone #{defaults_repo}")
  copy_local_defaults_to_remote(defaults_repo_name, container)

  Dir.chdir(defaults_repo_name)
  system("git add #{container}; git commit -m \"Updating [ #{container} ] defaults. Triggered by Docker build [ #{docker_tag} ]\"; git push origin master")
  
  git_tag = "#{container}/#{docker_tag}"
  
  existing_tag = %x[git tag -l #{git_tag}]
  if existing_tag != nil
    puts "Git tag [ #{git_tag} ] exists! Overwriting."
    system("git tag -d #{git_tag}; git push origin :refs/tags/#{git_tag}")
  end
    
  system("git tag -a #{git_tag} -m \"Updating [ #{container} ] defaults. Triggered by Docker build [ #{docker_tag} ]\"; git push origin #{git_tag}")
end

update_remote_defaults

