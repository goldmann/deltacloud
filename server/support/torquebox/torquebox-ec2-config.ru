require 'rubygems'

ENV['API_DRIVER'] = 'ec2'

require 'server.rb'
run Sinatra::Application
