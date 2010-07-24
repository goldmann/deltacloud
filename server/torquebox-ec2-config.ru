require 'rubygems'
require 'sinatra'

ENV['API_DRIVER'] = 'ec2'
set :root, ENV['RACK_ROOT']

require 'server.rb'
run Sinatra::Application
