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


require 'deltacloud/base_driver'

module Deltacloud
  module Drivers
    module Mock
class MockDriver < Deltacloud::BaseDriver

  #
  # Flavors
  #

  ( FLAVORS = [
    Flavor.new({
      :id=>'m1-small',
      :memory=>1.7,
      :storage=>160,
      :architecture=>'i386',
    }),
    Flavor.new({
      :id=>'m1-large',
      :memory=>7.5,
      :storage=>850,
      :architecture=>'x86_64',
    }),
    Flavor.new({
      :id=>'m1-xlarge',
      :memory=>15,
      :storage=>1690,
      :architecture=>'x86_64',
    }),
    Flavor.new({
      :id=>'c1-medium',
      :memory=>1.7,
      :storage=>350,
      :architecture=>'x86_64',
    }),
    Flavor.new({
      :id=>'c1-xlarge',
      :memory=>7,
      :storage=>1690,
      :architecture=>'x86_64',
    }),
  ] ) unless defined?( FLAVORS )

  ( REALMS = [
    Realm.new({
      :id=>'us',
      :name=>'United States',
      :limit=>:unlimited,
      :state=>'AVAILABLE',
    }),
    Realm.new({
      :id=>'eu',
      :name=>'Europe',
      :limit=>:unlimited,
      :state=>'AVAILABLE',
    }),
  ] ) unless defined?( REALMS )

  define_hardware_profile('m1-small') do
    cpu              1
    memory         1.7 * 1024
    storage        160
    architecture 'i386'
  end

  define_hardware_profile('m1-large') do
    cpu                2
    memory           (7.5*1024 .. 15*1024), :default => 10 * 1024
    storage          [ 850, 1024 ]
    architecture     'x86_64'
  end

  define_hardware_profile('m1-xlarge') do
    cpu              4
    memory           (12*1024 .. 32*1024)
    storage          [ 1024, 2048, 4096 ]
    architecture     'x86_64'
  end

  # Some clouds tell us nothing about hardware profiles (e.g., OpenNebula)
  define_hardware_profile 'opaque'

  define_instance_states do
    start.to( :pending )       .on( :create )

    pending.to( :running )     .automatically

    running.to( :running )     .on( :reboot )
    running.to( :stopped )     .on( :stop )

    stopped.to( :running )     .on( :start )
    stopped.to( :finish )      .on( :destroy )
  end

  feature :instances, :user_name

  def initialize
    if ENV["DELTACLOUD_MOCK_STORAGE"]
      @storage_root = ENV["DELTACLOUD_MOCK_STORAGE"]
    elsif ENV["USER"]
      @storage_root = File::join("/var/tmp", "deltacloud-mock-#{ENV["USER"]}")
    else
      raise "Please set either the DELTACLOUD_MOCK_STORAGE or USER environment variable"
    end
    if ! File::directory?(@storage_root)
      FileUtils::rm_rf(@storage_root)
      FileUtils::mkdir_p(@storage_root)
      data = Dir::glob(File::join(File::dirname(__FILE__), "data", "*"))
      FileUtils::cp_r(data, @storage_root)
    end
  end

  def flavors(credentials, opts=nil)
    return FLAVORS if ( opts.nil? )
    results = FLAVORS
    results = filter_on( results, :id, opts )
    results = filter_on( results, :architecture, opts )
    results
  end

  def realms(credentials, opts=nil)
    return REALMS if ( opts.nil? )
    results = REALMS
    results = filter_on( results, :id, opts )
    results
  end

  #
  # Images
  #

  def images(credentials, opts=nil )
    check_credentials( credentials )
    images = []
    Dir[ "#{@storage_root}/images/*.yml" ].each do |image_file|
      image = YAML.load( File.read( image_file ) )
      image[:id] = File.basename( image_file, ".yml" )
      image[:name] = image[:description]
      images << Image.new( image )
    end
    images = filter_on( images, :id, opts )
    images = filter_on( images, :architecture, opts )
    if ( opts && opts[:owner_id] == 'self' )
      images = images.select{|e| e.owner_id == credentials.user }
    else
      images = filter_on( images, :owner_id, opts )
    end
    images.sort_by{|e| [e.owner_id,e.description]}
  end

  #
  # Instances
  #

  def instances(credentials, opts=nil)
    check_credentials( credentials )
    instances = []
    Dir[ "#{@storage_root}/instances/*.yml" ].each do |instance_file|
      instance = YAML.load( File.read( instance_file ) )
      if ( instance[:owner_id] == credentials.user )
        instance[:id] = File.basename( instance_file, ".yml" )
        instance[:actions] = instance_actions_for( instance[:state] )
        instances << Instance.new( instance )
      end
    end
    instances = filter_on( instances, :id, opts )
    instances = filter_on( instances, :state, opts )
    instances
  end

  def create_instance(credentials, image_id, opts)
    check_credentials( credentials )
    ids = Dir[ "#{@storage_root}/instances/*.yml" ].collect{|e| File.basename( e, ".yml" )}

    count = 0
    while true
      next_id = "inst" + count.to_s
      if not ids.include?(next_id)
        break
      end
      count = count + 1
    end

    realm_id = opts[:realm_id]
    if ( realm_id.nil? )
      realm = realms(credentials).first
      ( realm_id = realm.id ) if realm
    end

    hwp = find_hardware_profile(credentials, opts[:hwp_id], image_id)

    name = opts[:name] || "i-#{Time.now.to_i}"

    instance = {
      :name=>name,
      :state=>'RUNNING',
      :image_id=>image_id,
      :owner_id=>credentials.user,
      :public_addresses=>["#{image_id}.#{next_id}.public.com"],
      :private_addresses=>["#{image_id}.#{next_id}.private.com"],
      :flavor_id=>hwp.name,
      :instance_profile => InstanceProfile.new(hwp.name, opts),
      :realm_id=>realm_id,
      :actions=>instance_actions_for( 'RUNNING' )
    }
    File.open( "#{@storage_root}/instances/#{next_id}.yml", 'w' ) {|f|
      YAML.dump( instance, f )
    }
    instance[:id] = next_id
    Instance.new( instance )
  end

  def start_instance(credentials, id)
    instance_file = "#{@storage_root}/instances/#{id}.yml"
    instance_yml  = YAML.load( File.read( instance_file ) )
    instance_yml[:state] = 'RUNNING'
    File.open( instance_file, 'w' ) do |f|
      f << YAML.dump( instance_yml )
    end
    Instance.new( instance_yml )
  end

  def reboot_instance(credentials, id)
    instance_file = "#{@storage_root}/instances/#{id}.yml"
    instance_yml  = YAML.load( File.read( instance_file ) )
    instance_yml[:state] = 'RUNNING'
    File.open( instance_file, 'w' ) do |f|
      f << YAML.dump( instance_yml )
    end
    Instance.new( instance_yml )
  end

  def stop_instance(credentials, id)
    instance_file = "#{@storage_root}/instances/#{id}.yml"
    instance_yml  = YAML.load( File.read( instance_file ) )
    instance_yml[:state] = 'STOPPED'
    File.open( instance_file, 'w' ) do |f|
      f << YAML.dump( instance_yml )
    end
    Instance.new( instance_yml )
  end


  def destroy_instance(credentials, id)
    check_credentials( credentials )
    FileUtils.rm( "#{@storage_root}/instances/#{id}.yml" )
  end

  #
  # Storage Volumes
  #

  def storage_volumes(credentials, opts=nil)
    check_credentials( credentials )
    volumes = []
    Dir[ "#{@storage_root}/storage_volumes/*.yml" ].each do |storage_volume_file|
      storage_volume = YAML.load( File.read( storage_volume_file ) )
      if ( storage_volume[:owner_id] == credentials.user )
        storage_volume[:id] = File.basename( storage_volume_file, ".yml" )
        volumes << StorageVolume.new( storage_volume )
      end
    end
    volumes = filter_on( volumes, :id, opts )
    volumes
  end

  #
  # Storage Snapshots
  #

  def storage_snapshots(credentials, opts=nil)
    check_credentials( credentials )
    snapshots = []
    Dir[ "#{@storage_root}/storage_snapshots/*.yml" ].each do |storage_snapshot_file|
      storage_snapshot = YAML.load( File.read( storage_snapshot_file ) )
      if ( storage_snapshot[:owner_id] == credentials.user )
        storage_snapshot[:id] = File.basename( storage_snapshot_file, ".yml" )
        snapshots << StorageSnapshot.new( storage_snapshot )
      end
    end
    snapshots = filter_on( snapshots, :id, opts )
    snapshots
  end

  private

  def check_credentials(credentials)
    if ( credentials.user != 'mockuser' )
      raise Deltacloud::AuthException.new
    end

    if ( credentials.password != 'mockpassword' )
      raise Deltacloud::AuthException.new
    end
  end


end

    end
  end
end
