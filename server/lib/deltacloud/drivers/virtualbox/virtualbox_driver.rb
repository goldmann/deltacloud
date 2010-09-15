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

# INSTALLATION:
# 1. You need VirtualBox and VBoxManage tool installed
# 2. You need to setup some images manually inside VirtualBox
# 3. You need to install 'Guest Additions' to this images for metrics
# 4. You need a lot of hard drive space ;-)

# NETWORKING:
# For now, the VM is always started with bridged networking. The NIC
# it uses defaults to eth0, but may be overriden with the VIRTUALBOX_NIC
# environment variable. This should be the NIC name as expected by Virtualbox.
# For example, on my Macbook Pro this is 'en1: AirPort'

require 'deltacloud/base_driver'

module Deltacloud
  module Drivers
    module Virtualbox
      class VirtualboxDriver < Deltacloud::BaseDriver

        VBOX_MANAGE_PATH = '/usr/bin'

        ( REALMS = [
          Realm.new({
            :id => 'local',
            :name => 'localhost',
            :limit => 100,
            :state => 'AVAILABLE'
          })
        ] ) unless defined?( REALMS )

        define_hardware_profile 'small' do
          cpu           1
          memory        0.5
          storage       1
          architecture  `uname -m`.strip
        end

        # define_hardware_profile 'medium' do
        #   cpu           1
        #   memory        1
        #   storage       1
        #   architecture  `uname -m`.strip
        # end

        # define_hardware_profile 'large' do
        #   cpu           2
        #   memory        2
        #   storage       1
        #   architecture  `uname -m`.strip
        # end

        define_instance_states do
          start.to( :pending )       .on( :create )
          pending.to( :running )     .automatically
          running.to( :stopped )     .on( :stop )
          stopped.to( :running )     .on( :start )
          stopped.to( :finish )      .on( :destroy )
        end

        def realms(credentials, opts = nil)
          return REALMS if ( opts.nil? )
          results = REALMS
          results = filter_on( results, :id, opts )
          results
        end

        def images(credentials, opts = nil)
          images = convert_images(vbox_client('list vms'))
          images = filter_on( images, :id, opts )
          images = filter_on( images, :architecture, opts )
          images.sort_by{|e| [e.owner_id, e.description]}
        end

        def instances(credentials, opts = nil)
          instances = convert_instances(vbox_client('list vms'))
          instances = filter_on( instances, :id, opts )
          instances = filter_on( instances, :state, opts )
          instances = filter_on( instances, :image_id, opts )
          instances
        end

        def create_instance(credentials, image_id, opts)
          instance = instances(credentials, { :image_id => image_id }).first
          name = opts[:name]
          if name.nil? or name.empty?
            # random uniqueish name w/o having to pull in UUID gem
            name = "#{instance.name} - #{(Time.now.to_f * 1000).to_i}#{rand(1000)}"
          end
          hwp = find_hardware_profile(credentials, opts[:hwp_id], image_id)

          # Create new virtual machine, UUID for this machine is returned
          vm=vbox_client("createvm --name '#{name}' --register")
          new_uid = vm.split("\n").select { |line| line=~/^UUID/ }.first.split(':').last.strip

          # Add Hardware profile to this machine
          memory = 0.5
          ostype = "Linux"
          cpu = '1'
          unless hwp.nil?
            memory = hwp.memory.value
            cpu = hwp.cpu.value
          end

          memory = ((memory*1.024)*1000).to_i

          nic = ENV['VIRTUALBOX_NIC'] || 'eth0'
          vbox_client("modifyvm '#{new_uid}' --ostype #{ostype} --memory #{memory} --vram 16 --nic1 bridged --bridgeadapter1 '#{nic}' --cableconnected1 on --cpus #{cpu}")

          # Add storage
          # This will 'reuse' existing image
          location = instance_volume_location(instance.id)
          new_location = File.join(File.dirname(location), name+'.vdi')

          # This need to be in fork, because it takes some time with large images
          Thread.new do
            vbox_client("clonehd '#{location}' '#{new_location}' --format VDI")
            vbox_client("storagectl '#{new_uid}' --add ide --name 'IDE Controller' --controller PIIX4")
            vbox_client("storageattach '#{new_uid}' --storagectl 'IDE Controller' --port 0 --device 0 --type hdd --medium '#{new_location}'")
            start_instance(credentials, new_uid)
            if opts[:user_data]
              user_data = opts[:user_data].gsub("\n", '') # remove newlines from base64 encoded text
              vbox_client("guestproperty set #{new_uid} /Deltacloud/UserData #{user_data}")
            end
          end
          instances(credentials, :id => new_uid).first
        end

        def reboot_instance(credentials, id)
          vbox_client("controlvm '#{id}' reset")
        end

        def stop_instance(credentials, id)
          vbox_client("controlvm '#{id}' poweroff")
        end

        def start_instance(credentials, id)
          instance = instances(credentials, { :id => id }).first
          vbox_client("startvm '#{id}'")
        end

        def destroy_instance(credentials, id)
          vbox_client("controlvm '#{id}' poweroff")
        end

        def storage_volumes(credentials, opts = nil)
          volumes = []
          require 'pp'
          instances(credentials, {}).each do |image|
            raw_image = convert_image(vbox_vm_info(image.id))
            hdd_id = volume_uuid(raw_image)
            next unless hdd_id
            volumes << convert_volume(vbox_client("showhdinfo '#{hdd_id}'"))
          end
          filter_on( volumes, :id, opts )
        end

        private

        def vbox_client(cmd)
          # puts "!!!"
          # puts "!!!"
          # puts "!!! Executing cmd #{cmd}"
          output = `#{VBOX_MANAGE_PATH}/VBoxManage -q #{cmd}`.strip
          # puts output
          # puts "!!!"
          # puts "!!!"
          # puts
          output
        end

        def vbox_vm_info(uid)
          vbox_client("showvminfo --machinereadable '#{uid}'")
        end

        def convert_instances(instances)
          vms = []
          instances.split("\n").each do |image|
            image_id = image.match(/^\"(.+)\" \{(.+)\}$/).to_a.last
            raw_image = convert_image(vbox_vm_info(image_id))
            volume = convert_volume(vbox_get_volume(volume_uuid(raw_image)))
            hwp_name = 'small'
            vms << Instance.new({
              :id => raw_image[:uuid],
              :image_id => volume ? raw_image[:uuid] : '',
              :name => raw_image[:name],
              :state => convert_state(raw_image[:vmstate], volume),
              :owner_id => ENV['USER'] || ENV['USERNAME'] || 'nobody',
              :realm_id => 'local',
              :public_addresses => vbox_get_ip(raw_image[:uuid]),
              :private_addresses => vbox_get_ip(raw_image[:uuid]),
              :actions => instance_actions_for(convert_state(raw_image[:vmstate], volume)),
              :instance_profile =>InstanceProfile.new(hwp_name)
            })
          end
          return vms
        end

        # Warning: You need VirtualHost guest additions for this
        def vbox_get_ip(uuid)
          raw_ip = vbox_client("guestproperty get #{uuid} /VirtualBox/GuestInfo/Net/0/V4/IP")
          raw_ip = raw_ip.split(':').last.strip
          if raw_ip.eql?('No value set!') or raw_ip.eql?('Value')
            return []
          else
            return [raw_ip]
          end
        end

        def vbox_get_volume(uuid)
          vbox_client("showhdinfo #{uuid}")
        end

        def volume_uuid(raw_image)
          uuid = raw_image['ide controller-imageuuid-0-0'.to_sym]
          uuid = raw_image['sata controller-imageuuid-0-0'.to_sym] if uuid.nil?
          uuid
        end

        def convert_state(state, volume)
          return 'PENDING' if volume.nil?
          state = state.strip.upcase
          case state
          when 'POWEROFF' then 'STOPPED'
          else
            state
          end
        end

        def convert_image(image)
          img = {}
          image.split("\n").each do |i|
            si = i.split('=')
            key = si.first.gsub('"', '').strip.downcase
            value = si.last.strip.gsub('"', '')
            img[key.to_sym] = value
          end
          return img
        end

        def instance_volume_location(instance_id)
          volume_uuid = volume_uuid(convert_image(vbox_vm_info(instance_id)))
          convert_raw_volume(vbox_get_volume(volume_uuid))[:location]
        end

        def convert_raw_volume(volume)
          vol = {}
          volume.split("\n").each do |v|
            v = v.split(':')
            next unless v.first
            vol[:"#{v.first.strip.downcase.gsub(/\W/, '-')}"] = v.last.strip
          end
          return vol
        end

        def convert_volume(volume)
          vol = convert_raw_volume(volume)
          return nil unless vol[:uuid]
          StorageVolume.new(
            :id => vol[:uuid],
            :created => Time.now,
            :state => 'AVAILABLE',
            :capacity => vol["logical-size".to_sym],
            :instance_id => vol["in-use-by-vms".to_sym],
            :device => vol[:type]
          )
        end

        def convert_images(images)
          vms = []
          images.split("\n").each do |image|
            image_id = image.match(/^\"(.+)\" \{(.+)\}$/).to_a.last
            raw_image = convert_image(vbox_vm_info(image_id))
            volume = convert_volume(vbox_get_volume(volume_uuid(raw_image)))
            next unless volume
            capacity = ", #{volume.capacity} HDD"
            vms << Image.new(
              :id => raw_image[:uuid],
              :name => raw_image[:name],
              :description => "#{raw_image[:memory]} MB RAM, #{raw_image[:cpu] || 1} CPU#{capacity}",
              :owner_id => ENV['USER'] || ENV['USERNAME'] || 'nobody',
              :architecture => `uname -m`.strip
            )
          end
          return vms
        end
      end
    end
  end
end
