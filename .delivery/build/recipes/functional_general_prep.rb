#
# Cookbook Name:: build
# Recipe:: functional_general_prep
#
# Copyright (c) 2015 The Authors, All Rights Reserved.

include_recipe 'build::prepare_deps'
include_recipe 'build::prepare_acceptance'

cookbook_file attributes_functional_file do
  source 'functional.json'
end

directory ::File.join(node['delivery']['workspace']['repo'], '.chef', 'nodes') do
  action :create
end
