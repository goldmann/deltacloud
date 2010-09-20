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
require 'virtualbox'

module Deltacloud
  module Drivers
    module Virtualbox
      class VirtualboxDriver < Deltacloud::BaseDriver

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
          images = convert_images(VirtualBox::VM.all)
          images = filter_on( images, :id, opts )
          images = filter_on( images, :architecture, opts )
          images.sort_by{|e| [e.owner_id, e.description]}
        end

        def instances(credentials, opts = nil)
          instances = convert_instances(VirtualBox::VM.all)
          instances = filter_on( instances, :id, opts )
          instances = filter_on( instances, :state, opts )
          instances = filter_on( instances, :image_id, opts )
          instances
        end

        def create_instance(credentials, image_id, opts)
          image = images(credentials, { :id => image_id }).first
          name = opts[:name]
          if name.nil? or name.empty?
            # random uniqueish name w/o having to pull in UUID gem
            name = "#{image.name} - #{(Time.now.to_f * 1000).to_i}#{rand(1000)}"
          end
          hwp = find_hardware_profile(credentials, opts[:hwp_id], image_id)

          parent_vm = VirtualBox::VM.find(image.id)
          # Create new virtual machine
          vm = VirtualBox::VM.create(name, parent_vm.os_type_id)
          new_uid = vm.uuid

          # Add Hardware profile to this machine
          memory = parent_vm.memory_size
          ostype = parent_vm.os_type_id
          cpu = parent_vm.cpu_count
          unless hwp.nil?
            memory = ((hwp.memory.value*1.024)*1000).to_i
            cpu = hwp.cpu.value.to_i
          end
          vm.memory_size = memory
          vm.os_type_id = ostype
          vm.cpu_count = cpu
          vm.vram_size = 16
          vm.network_adapters[0].enabled = true
          vm.network_adapters[0].attachment_type = parent_vm.network_adapters[0].attachment_type
          vm.network_adapters[0].host_interface = parent_vm.network_adapters[0].host_interface
          vm.save

          # Clone the disk image in a separate thread because it can take a long time
          Thread.new do
            # Reload the vm objects because they probably aren't safe to
            # reuse across threads
            parent_vm = VirtualBox::VM.find(image.id)
            vm = VirtualBox::VM.find(new_uid)

            # Add storage
            # This will 'reuse' existing image
            parent_hdd = hard_disk(parent_vm)
            new_location = File.join(File.dirname(parent_hdd.location), "#{name}.vdi")

            new_hd = parent_hdd.clone(new_location, "VDI")
            vm.add_storage_controller('IDE Controller', :ide, :piix4)
            vm.attach_storage('IDE Controller', 0, 0, :hard_disk, new_hd.uuid)
            vm.start
            if opts[:user_data]
              user_data = opts[:user_data].gsub("\n", '') # remove newlines from base64 encoded text
              vm.guest_property["/Deltacloud/UserData"] = user_data
            end
          end
          instances(credentials, :id => new_uid).first
        end

        def reboot_instance(credentials, id)
          vm = VirtualBox::VM.find(id)
          vm.control(:reset)
        end

        def stop_instance(credentials, id)
          vm = VirtualBox::VM.find(id)
          unless vm.shutdown
            vm.stop
          end
        end

        def start_instance(credentials, id)
          vm = VirtualBox::VM.find(id)
          vm.start
        end

        def destroy_instance(credentials, id)
          vm = VirtualBox::VM.find(id)
          vm.destroy(:destroy_medium => :delete)
        end

        private

        def convert_instances(instances)
          vms = []
          hwp_name = 'small' # TODO: Pull from extra_data
          instances.each do |instance|
            volume = convert_volume(instance)
            state = convert_state(instance.state, volume)
            ip = vbox_get_ip(instance)
            vms << Instance.new(:id => instance.uuid,
                                :image_id => '', # TODO: Pull from extra_data
                                :name => instance.name,
                                :state => state,
                                :owner_id => ENV['USER'] || ENV['USERNAME'] || 'nobody',
                                :realm_id => 'local',
                                :public_addresses => ip,
                                :private_addresses => ip,
                                :actions => instance_actions_for(state),
                                :instance_profile => InstanceProfile.new(hwp_name))
          end
          vms
        end

        # Warning: You need VirtualHost guest additions for this
        def vbox_get_ip(instance)
          ip = instance.guest_property["/VirtualBox/GuestInfo/Net/0/V4/IP"]
          ip.nil? ? [] : [ip]
        end

        def convert_state(state, volume)
          return 'PENDING' if volume.nil?
          state = state.to_s.strip.upcase
          case state
          when 'POWEROFF' then 'STOPPED'
          when 'POWERED_OFF' then 'STOPPED'
          else
            state
          end
        end

        def convert_volume(vm)
          hdd = hard_disk(vm)
          return nil if hdd.nil?
          StorageVolume.new(:id => hdd.uuid,
                            :created => Time.now,
                            :state => 'AVAILABLE',
                            :capacity => hdd.logical_size,
                            :instance_id => vm.uuid,
                            :device => hdd.type)
        end

        def hard_disk(vm)
          attachment = vm.medium_attachments.select { |ma| ma.type == :hard_disk }.first
          attachment.nil? ? nil : attachment.medium
        end

        def convert_images(images)
          vms = []
          images.each do |image|
            hdd = hard_disk(image)
            next unless hdd
            capacity = ", #{hdd.logical_size} MBytes HDD"
            vms << Image.new(:id => image.uuid,
                             :name => image.name,
                             :description => "#{image.memory_size} MB RAM, #{image.cpu_count} CPU#{capacity}",
                             :owner_id => ENV['USER'] || ENV['USERNAME'] || 'nobody',
                             :architecture => `uname -m`.strip)
          end
          vms
        end

      end
    end
  end
end
