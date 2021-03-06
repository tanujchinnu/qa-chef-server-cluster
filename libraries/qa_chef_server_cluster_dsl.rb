#
# Cookbook Name:: qa-chef-server-cluster
# Libraries:: helpers
#
# Author: Patrick Wright <patrick@chef.io>
# Copyright (C) 2015, Chef Software, Inc. <legal@getchef.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require_relative './server_flavor_helper'

# rubocop:disable Metrics/ModuleLength
module QaChefServerCluster
  module DSL
    include ChefIngredientCookbook::Helpers
    include QaChefServerCluster::ServerFlavorHelper

    SUPPORTED_FLAVORS = %w(chef_server enterprise_chef open_source_chef)

    def current_flavor
      flavor = node['qa-chef-server-cluster']['chef-server']['flavor']
      unless SUPPORTED_FLAVORS.include?(flavor)
        raise "Chef Server flavor '#{flavor}' not supported.  Must be one of: #{SUPPORTED_FLAVORS}"
      end
      flavor
    end

    #
    # Returns a ChefServer instance for the current_flavor
    #
    def current_server
      case current_flavor
      when 'chef_server'
        chef_server_flavor
      when 'open_source_chef'
        open_source_chef_flavor
      when 'enterprise_chef'
        enterprise_chef_flavor
      else
        raise "Chef Server flavor '#{current_flavor}' not supported.  Must be one of: #{SUPPORTED_FLAVORS}"
      end
    end

    def create_chef_server_directory
      directory current_server.config_path do
        mode 0755
        recursive true
      end
    end

    def download_bootstrap_files(machine_name = node['bootstrap-backend'])
      # download more server files
      # Note: this fails and rescues and returns nil when one of these files
      # does not exist
      %w(pivotal.pem webui_pub.pem private-chef-secrets.json webui_priv.pem).each do |opscode_file|
        machine_file "/etc/opscode/#{opscode_file}" do
          local_path "#{node['qa-chef-server-cluster']['chef-server']['file-dir']}/#{opscode_file}"
          machine machine_name
          action :download
        end
      end
    end

    def filter_existing_files(files = {})
      ret = {}
      files.each do |remote_path, local_path|
        if ::File.exists?(local_path)
          ret[remote_path] = local_path
        else
          Chef::Log.warn("File #{local_path} not found, not copying to #{remote_path}")
        end
      end

      ret
    end

    # rubocop:disable Metrics/AbcSize
    def download_logs(machine_name)
      return unless node['qa-chef-server-cluster']['download-logs']
      # create dedicated machine log directory
      machine_log_dir = directory ::File.join(Chef::Config[:chef_repo_path], 'logs', machine_name) do
        mode 0700
        recursive true
      end

      # download chef-stacktrace.out if it exists
      machine_file ::File.join('', 'var', 'chef', 'cache', 'chef-stacktrace.out') do
        local_path ::File.join(machine_log_dir.name, 'chef-stacktrace.out')
        machine machine_name
        action :download
      end

      # run chef-server-ctl gather-logs and create symlink
      machine machine_name do
        run_list ['qa-chef-server-cluster::run-gather-logs']
      end

      # download gather logs archive if it exists
      machine_file ::File.join('', 'var', 'chef', 'cache', 'latest-gather-logs.tbz2') do
        local_path ::File.join(machine_log_dir.name, "#{machine_name}-logs.tbz2")
        machine machine_name
        action :download
      end

      # TODO: Commenting this for now.  This will be useful once we can archive
      # and view output files in Delivery.  Then we can work out the details.
      # For now, extracting this way is causing failures.
      # extract tarball for easy access
      # execute "`which tar` -xzvf #{machine_name}-logs.tbz2" do
      #   cwd machine_log_dir.name
      #   only_if { ::File.exists?("#{machine_log_dir.name}/#{machine_name}-logs.tbz2") }
      # end
    end
    # rubocop:enable Metrics/AbcSize

    def symbolize_keys_deep!(h)
      Chef::Log.debug("#{h.inspect} is a hash with string keys, make them symbols")
      h.keys.each do |k|
        ks    = k.to_sym
        h[ks] = h.delete k
        symbolize_keys_deep! h[ks] if h[ks].is_a? Hash
      end
    end

    def check_backend_ha_status(expected_status)
      ruby_block "is #{expected_status} backend?" do
        block do
          current_cluster_status = Mixlib::ShellOut.new('cat /var/opt/opscode/keepalived/current_cluster_status')
          current_cluster_status.run_command
          server_status = current_cluster_status.stdout.strip!
          if server_status != expected_status
            raise "Expected cluster status '#{expected_status}', but got actual status '#{server_status}'"
          else
            Chef::Log.info "backend has taken over as #{expected_status}!"
          end
        end
        # retry every 15 secs for 10 mins
        retries 4 * 10
        retry_delay 15
      end
    end

    def installed_chef_server_packages
      # https://github.com/rackerlabs/ohai-plugins/blob/master/plugins/packages.rb
      # TODO: how do I use this???

      # collect installed server packages
      installed_packages = []
      %w(chef-server-core chef-server private-chef).each do |package|
        installed_packages << package if package_installed?(package)
      end
      installed_packages
    end

    def package_installed?(package_name)
      case node['platform_family']
      when 'debian'
        query_string = "dpkg-query -W #{package_name}"
      when 'rhel'
        query_string = "rpm -qa | grep #{package_name}"
      when 'chefspec'
        return package_name == node['qa-chef-server-cluster']['chefspec']['upgrade_flavor'] ? true : false
      else
        raise "Need to add package query string for #{node['platform_family']}"
      end

      query = Mixlib::ShellOut.new(query_string)
      query.run_command
      !query.error?
    end

    def upgrade_from_server_flavor(installed_packages)
      raise 'Must pass an array' unless installed_packages.is_a?(Array)
      # elsif (installed_packages & %w( chef-server private-chef )).present?
      #   # chef-server and private-chef installed... what should I do in this edge case?
      if installed_packages.include?('chef-server-core')
        # upgrade from chef-server-core
        server = chef_server_flavor
      elsif installed_packages.include?('private-chef')
        # upgrade from private-chef
        server = enterprise_chef_flavor
      elsif installed_packages.include?('chef-server')
        # upgrade from chef-server
        server = open_source_chef_flavor
      else
        raise 'No installed Chef Server package found.'
      end
      server
    end
  end
end
# rubocop:enable Metrics/ModuleLength

Chef::Recipe.send(:include, ::QaChefServerCluster::DSL)
Chef::Resource.send(:include, ::QaChefServerCluster::DSL)
Chef::Provider.send(:include, ::QaChefServerCluster::DSL)
