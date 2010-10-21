#
# Copyright (C) 2009  Red Hat, Inc.
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.  The
# ASF licenses this file to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance with the
# License.  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations
# under the License.

require 'nokogiri'
require 'rest_client'
require 'base64'
require 'logger'

module DeltaCloud

  # Get a new API client instance
  #
  # @param [String, user_name] API user name
  # @param [String, password] API password
  # @param [String, user_name] API URL (eg. http://localhost:3001/api)
  # @return [DeltaCloud::API]
  def self.new(user_name, password, api_url, &block)
    API.new(user_name, password, api_url, &block)
  end

  # Check given credentials if their are valid against
  # backend cloud provider
  #
  # @param [String, user_name] API user name
  # @param [String, password] API password
  # @param [String, user_name] API URL (eg. http://localhost:3001/api)
  # @return [true|false]
  def self.valid_credentials?(user_name, password, api_url)
    api=API.new(user_name, password, api_url)
    result = false
    api.request(:get, '', :force_auth => '1') do |response|
      result = true if response.code.eql?(200)
    end
    return result
  end

  # Return a API driver for specified URL
  #
  # @param [String, url] API URL (eg. http://localhost:3001/api)
  def self.driver_name(url)
    API.new(nil, nil, url).driver_name
  end

  def self.define_class(name)
    @defined_classes ||= []
    if @defined_classes.include?(name)
      self.module_eval("API::#{name}")
    else
      @defined_classes << name unless @defined_classes.include?(name)
      API.const_set(name, Class.new)
    end
  end

  def self.classes
    @defined_classes || []
  end

  class API
    attr_accessor :logger
    attr_reader   :api_uri, :driver_name, :api_version, :features, :entry_points

    def initialize(user_name, password, api_url, opts={}, &block)
      opts[:version] = true
      @logger = opts[:verbose] ? Logger.new(STDERR) : []
      @username, @password = user_name, password
      @api_uri = URI.parse(api_url)
      @features, @entry_points = {}, {}
      @verbose = opts[:verbose] || false
      discover_entry_points
      yield self if block_given?
    end

    def connect(&block)
      yield self
    end

    # Return API hostname
    def api_host; @api_uri.host ; end

    # Return API port
    def api_port; @api_uri.port ; end

    # Return API path
    def api_path; @api_uri.path ; end

    # Define methods based on 'rel' attribute in entry point
    # Two methods are declared: 'images' and 'image'
    def declare_entry_points_methods(entry_points)
      logger = @logger
      API.instance_eval do
        entry_points.keys.select {|k| [:instance_states].include?(k)==false }.each do |model|
          define_method model do |*args|
            request(:get, "/#{model}", args.first) do |response|
              # Define a new class based on model name
              c = DeltaCloud.define_class("#{model.to_s.classify}")
              # Create collection from index operation
              base_object_collection(c, model, response)
            end
          end
          logger << "[API] Added method #{model}\n"
          define_method :"#{model.to_s.singularize}" do |*args|
            request(:get, "/#{model}/#{args[0]}") do |response|
              # Define a new class based on model name
              c = DeltaCloud.define_class("#{model.to_s.classify}")
              # Build class for returned object
              base_object(c, model, response)
            end
          end
          logger << "[API] Added method #{model.to_s.singularize}\n"
          define_method :"fetch_#{model.to_s.singularize}" do |url|
            id = url.grep(/\/#{model}\/(.*)$/)
            self.send(model.to_s.singularize.to_sym, $1)
          end
        end
      end
    end

    def base_object_collection(c, model, response)
      collection = []
      Nokogiri::XML(response).xpath("#{model}/#{model.to_s.singularize}").each do |item|
        c.instance_eval do
          attr_accessor :id
          attr_accessor :uri
        end
        collection << xml_to_class(c, item)
      end
      return collection
    end

    # Add default attributes [id and href] to class
    def base_object(c, model, response)
      obj = nil
      Nokogiri::XML(response).xpath("#{model.to_s.singularize}").each do |item|
        c.instance_eval do
          attr_accessor :id
          attr_accessor :uri


        end
        obj = xml_to_class(c, item)
      end
      return obj
    end

    # Convert XML response to defined Ruby Class
    def xml_to_class(c, item)
      obj = c.new
      # Set default attributes
      obj.id = item['id']
      api = self
      c.instance_eval do
        define_method :method_missing do |method|
            warn "[WARNING] Method '#{method}' is not available for this resource (#{c.name})."
            return nil
        end
        define_method :client do
          api
        end
      end
      obj.uri = item['href']
      logger = @logger
      logger << "[DC] Creating class #{obj.class.name}\n"
      obj.instance_eval do
        # Declare methods for all attributes in object
        item.xpath('./*').each do |attribute|
          # If attribute is a link to another object then
          # create a method which request this object from API
          if api.entry_points.keys.include?(:"#{attribute.name}s")
            c.instance_eval do
              define_method :"#{attribute.name.sanitize}" do
                client.send(:"#{attribute.name}", attribute['id'] )
              end
              logger << "[DC] Added #{attribute.name} to class #{obj.class.name}\n"
            end
          else
            # Define methods for other attributes
            c.instance_eval do
              case attribute.name
                # When response cointains 'link' block, declare
                # methods to call links inside. This is used for instance
                # to dynamicaly create .stop!, .start! methods
                when "actions":
                  actions = []
                  attribute.xpath('link').each do |link|
                    actions << [link['rel'], link[:href]]
                  define_method :"#{link['rel'].sanitize}!" do |*params|
                      client.request(:"#{link['method']}", link['href'], {}, params.first || {})
                      @current_state = client.send(:"#{item.name}", item['id']).state
                      obj.instance_eval do |o|
                        def state
                          @current_state
                        end
                      end
                    end
                  end
                  define_method :actions do
                    actions.collect { |a| a.first }
                  end
                  define_method :actions_urls do
                    urls = {}
                    actions.each { |a| urls[a.first] = a.last }
                    urls
                  end
                # Property attribute is handled differently
                when "property":
                  attr_accessor :"#{attribute['name'].sanitize}"
                  if attribute['value'] =~ /^(\d+)$/
                    obj.send(:"#{attribute['name'].sanitize}=",
                      DeltaCloud::HWP::FloatProperty.new(attribute, attribute['name']))
                  else
                    obj.send(:"#{attribute['name'].sanitize}=",
                      DeltaCloud::HWP::Property.new(attribute, attribute['name']))
                  end
                # Public and private addresses are returned as Array
                when "public_addresses", "private_addresses":
                  attr_accessor :"#{attribute.name.sanitize}"
                  obj.send(:"#{attribute.name.sanitize}=",
                    attribute.xpath('address').collect { |address| address.text })
                # Value for other attributes are just returned using
                # method with same name as attribute (eg. .owner_id, .state)
                else
                  attr_accessor :"#{attribute.name.sanitize}"
                  obj.send(:"#{attribute.name.sanitize}=", attribute.text.convert)
                  logger << "[DC] Added method #{attribute.name}[#{attribute.text}] to #{obj.class.name}\n"
              end
            end
          end
        end
      end
      return obj
    end

    # Get /api and parse entry points
    def discover_entry_points
      return if discovered?
      request(:get, @api_uri.to_s) do |response|
        api_xml = Nokogiri::XML(response)
        @driver_name = api_xml.xpath('/api').first['driver']
        @api_version = api_xml.xpath('/api').first['version']
        logger << "[API] Version #{@api_version}\n"
        logger << "[API] Driver #{@driver_name}\n"
        api_xml.css("api > link").each do |entry_point|
          rel, href = entry_point['rel'].to_sym, entry_point['href']
          @entry_points.store(rel, href)
          logger << "[API] Entry point '#{rel}' added\n"
          entry_point.css("feature").each do |feature|
            @features[rel] ||= []
            @features[rel] << feature['name'].to_sym
            logger << "[API] Feature #{feature['name']} added to #{rel}\n"
          end
        end
      end
      declare_entry_points_methods(@entry_points)
    end

    def create_key(opts={}, &block)
      params = { :name => opts[:name] }
      key = nil
      request(:post, entry_points[:keys], {}, params) do |response|
        c = DeltaCloud.define_class("Key")
        key = base_object(c, :key, response)
        yield key if block_given?
      end
      return key
    end

    # Create a new instance, using image +image_id+. Possible optiosn are
    #
    #   name  - a user-defined name for the instance
    #   realm - a specific realm for placement of the instance
    #   hardware_profile - either a string giving the name of the
    #                      hardware profile or a hash. The hash must have an
    #                      entry +id+, giving the id of the hardware profile,
    #                      and may contain additional names of properties,
    #                      e.g. 'storage', to override entries in the
    #                      hardware profile
    def create_instance(image_id, opts={}, &block)
      name = opts[:name]
      realm_id = opts[:realm]
      user_data = opts[:user_data]
      key_name = opts[:key_name]
      security_group = opts[:security_group]

      params = {}
      ( params[:realm_id] = realm_id ) if realm_id
      ( params[:name] = name ) if name
      ( params[:user_data] = user_data ) if user_data
      ( params[:keyname] = key_name ) if key_name
      ( params[:security_group] = security_group) if security_group

      if opts[:hardware_profile].is_a?(String)
        params[:hwp_id] = opts[:hardware_profile]
      elsif opts[:hardware_profile].is_a?(Hash)
        opts[:hardware_profile].each do |k,v|
          params[:"hwp_#{k}"] = v
        end
      end

      params[:image_id] = image_id
      instance = nil

      request(:post, entry_points[:instances], {}, params) do |response|
        c = DeltaCloud.define_class("Instance")
        instance = base_object(c, :instance, response)
        yield instance if block_given?
      end

      return instance
    end


    def create_storage_volume(opts={}, &block)
      params = opts.dup
      params[:realm_id] ||= params.delete(:realm)
      storage_volume = nil
      
      request(:post, entry_points[:storage_volumes], {}, params) do |response|
        c = DeltaCloud.define_class("StorageVolume")
        storage_volume = base_object(c, :storage_volume, response)
        yield storage_volume if block_given?
      end

      storage_volume
    end

    # Basic request method
    #
    def request(*args, &block)
      conf = {
        :method => (args[0] || 'get').to_sym,
        :path => (args[1]=~/^http/) ? args[1] : "#{api_uri.to_s}#{args[1]}",
        :query_args => args[2] || {},
        :form_data => args[3] || {}
      }
      if conf[:query_args] != {}
        conf[:path] += '?' + URI.escape(conf[:query_args].collect{ |key, value| "#{key}=#{value}" }.join('&')).to_s
      end
      logger << "[#{conf[:method].to_s.upcase}] #{conf[:path]}\n"
      if conf[:method].eql?(:post)
        RestClient.send(:post, conf[:path], conf[:form_data], default_headers) do |response, request, block|
          if response.respond_to?('body')
            yield response.body if block_given?
          else
            yield response.to_s if block_given?
          end
        end
      else
        RestClient.send(conf[:method], conf[:path], default_headers) do |response, request, block|
          if response.respond_to?('body')
            yield response.body if block_given?
          else
            yield response.to_s if block_given?
          end
        end
      end
    end

    # Check if specified collection have wanted feature
    def feature?(collection, name)
      @features.has_key?(collection) && @features[collection].include?(name)
    end

    # List available instance states and transitions between them
    def instance_states
      states = []
      request(:get, entry_points[:instance_states]) do |response|
        Nokogiri::XML(response).xpath('states/state').each do |state_el|
          state = DeltaCloud::InstanceState::State.new(state_el['name'])
          state_el.xpath('transition').each do |transition_el|
            state.transitions << DeltaCloud::InstanceState::Transition.new(
              transition_el['to'],
              transition_el['action']
            )
          end
          states << state
        end
      end
      states
    end

    # Select instance state specified by name
    def instance_state(name)
      instance_states.select { |s| s.name.to_s.eql?(name.to_s) }.first
    end

    # Skip parsing /api when we already got entry points
    def discovered?
      true if @entry_points!={}
    end

    def documentation(collection, operation=nil)
      data = {}
      request(:get, "/docs/#{collection}") do |body|
        document = Nokogiri::XML(body)
        if operation
          data[:operation] = operation
          data[:description] = document.xpath('/docs/collection/operations/operation[@name = "'+operation+'"]/description').first.text.strip
          return false unless data[:description]
          data[:params] = []
          (document/"/docs/collection/operations/operation[@name='#{operation}']/parameter").each do |param|
            data[:params] << {
              :name => param['name'],
              :required => param['type'] == 'optional',
              :type => (param/'class').text
            }
          end
        else
          data[:description] = (document/'/docs/collection/description').text
          data[:collection] = collection
          data[:operations] = (document/"/docs/collection/operations/operation").collect{ |o| o['name'] }
        end
      end
      return Documentation.new(self, data)
    end

    private

    def default_headers
      # The linebreaks inserted every 60 characters in the Base64
      # encoded header cause problems under JRuby
      auth_header = "Basic "+Base64.encode64("#{@username}:#{@password}")
      auth_header.gsub!("\n", "")
      {
        :authorization => auth_header,
        :accept => "application/xml"
      }
    end

  end

  class Documentation

    attr_reader :api, :description, :params, :collection_operations
    attr_reader :collection, :operation

    def initialize(api, opts={})
      @description, @api = opts[:description], api
      @params = parse_parameters(opts[:params]) if opts[:params]
      @collection_operations = opts[:operations] if opts[:operations]
      @collection = opts[:collection]
      @operation = opts[:operation]
      self
    end

    def operations
      @collection_operations.collect { |o| api.documentation(@collection, o) }
    end

    class OperationParameter
      attr_reader :name
      attr_reader :type
      attr_reader :required
      attr_reader :description

      def initialize(data)
        @name, @type, @required, @description = data[:name], data[:type], data[:required], data[:description]
      end

      def to_comment
        "   # @param [#{@type}, #{@name}] #{@description}"
      end

    end

    private

    def parse_parameters(params)
      params.collect { |p| OperationParameter.new(p) }
    end

  end

  module InstanceState

    class State
      attr_reader :name
      attr_reader :transitions

      def initialize(name)
        @name, @transitions = name, []
      end
    end

    class Transition
      attr_reader :to
      attr_reader :action

      def initialize(to, action)
        @to = to
        @action = action
      end

      def auto?
        @action.nil?
      end
    end
  end

  module HWP

   class Property
      attr_reader :name, :unit, :value, :kind

      def initialize(xml, name)
        @name, @kind, @value, @unit = xml['name'], xml['kind'].to_sym, xml['value'], xml['unit']
        declare_ranges(xml)
        self
      end

      def present?
        ! @value.nil?
      end

      private

      def declare_ranges(xml)
        case xml['kind']
          when 'range':
            self.class.instance_eval do
              attr_reader :range
            end
            @range = { :from => xml.xpath('range').first['first'], :to => xml.xpath('range').first['last'] }
          when 'enum':
            self.class.instance_eval do
              attr_reader :options
            end
            @options = xml.xpath('enum/entry').collect { |e| e['value'] }
        end
      end

    end

    # FloatProperty is like Property but return value is Float instead of String.
    class FloatProperty < Property
      def initialize(xml, name)
        super(xml, name)
        @value = @value.to_f if @value
      end
    end
  end

end

class String

  unless method_defined?(:classify)
    # Create a class name from string
    def classify
      self.singularize.camelize
    end
  end

  unless method_defined?(:camelize)
    # Camelize converts strings to UpperCamelCase
    def camelize
      self.to_s.gsub(/\/(.?)/) { "::#{$1.upcase}" }.gsub(/(?:^|_)(.)/) { $1.upcase }
    end
  end

  unless method_defined?(:singularize)
    # Strip 's' character from end of string
    def singularize
      self.gsub(/s$/, '')
    end
  end

  # Convert string to float if string value seems like Float
  def convert
    return self.to_f if self.strip =~ /^([\d\.]+$)/
    self
  end

  # Simply converts whitespaces and - symbols to '_' which is safe for Ruby
  def sanitize
    self.gsub(/(\W+)/, '_')
  end

end
