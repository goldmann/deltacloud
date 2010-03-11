#
# Copyright (C) 2009  Red Hat, Inc.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

require "net/http"
require "net/https"
require 'rubygems'
require 'json'

#
# author: Michael Neale
# TODO: catch generic errors in JSON response and throw (probably)
#
module Deltacloud
  module Drivers
    module Rackspace

class RackspaceClient

  @@AUTH_API = URI.parse('https://auth.api.rackspacecloud.com/v1.0')

  def initialize(username, auth_key)
    http = Net::HTTP.new(@@AUTH_API.host,@@AUTH_API.port)
    http.use_ssl = true
    authed = http.get(@@AUTH_API.path, {'X-Auth-User' => username, 'X-Auth-Key' => auth_key})
    if authed.is_a?(Net::HTTPUnauthorized)
      raise Deltacloud::AuthException, "Failed to authenticate to Rackspace"
    elsif !authed.is_a?(Net::HTTPSuccess)
      backend_error!(resp)
    end
    @auth_token  = authed.header['X-Auth-Token']
    @service_uri = URI.parse(authed.header['X-Server-Management-Url'])
    @service = Net::HTTP.new(@service_uri.host, @service_uri.port)
    @service.use_ssl = true
  end

  def list_flavors
    JSON.parse(get('/flavors/detail'))['flavors']
  end

  def list_images
    JSON.parse(get('/images/detail'))['images']
  end

  def list_servers
      JSON.parse(get('/servers/detail'))['servers']
  end


  def load_server_details( server_id )
    JSON.parse(get("/servers/#{server_id}"))['server']
  end


  def start_server(image_id, flavor_id, name)
    json = { :server => { :name => name,
                          :imageId => image_id.to_i,
                          :flavorId => flavor_id.to_i }}.to_json
    # FIXME: The response has the root password in 'adminPass'; we somehow
    # need to communicate this back since it's the only place where we can
    # get it from
    JSON.parse(post("/servers", json, headers).body)["server"]
  end

  def delete_server(server_id)
    delete("/servers/#{server_id}", headers)
  end

  def reboot_server(server_id)
    json = { :reboot => { :type => :SOFT }}.to_json
    post("/servers/#{server_id}/action", json, headers)
  end


  def headers
    {"Accept" => "application/json", "X-Auth-Token" => @auth_token, "Content-Type" => "application/json"}
  end

  private
  def get(path)
    resp = @service.get(@service_uri.path + path, {"Accept" => "application/json", "X-Auth-Token" => @auth_token})
    unless resp.is_a?(Net::HTTPSuccess)
      backend_error!(resp)
    end
    resp.body
  end

  def post(path, json, headers)
    resp = @service.post(@service_uri.path + path, json, headers)
    unless resp.is_a?(Net::HTTPSuccess)
      backend_error!(resp)
    end
    resp
  end

  def delete(path, headers)
    resp = @service.delete(@service_uri.path + path, headers)
    unless resp.is_a?(Net::HTTPSuccess)
      backend_error!(resp)
    end
    resp
  end

  def backend_error!(resp)
    json = JSON.parse(resp.body)
    cause = json.keys[0]
    code = json[cause]["code"]
    message = json[cause]["message"]
    details = json[cause]["details"]
    raise Deltacloud::BackendError.new(code, cause, message, details)
  end

end
    end
  end
end
