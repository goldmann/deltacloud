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

require 'deltacloud/base_driver'
require 'yaml'

module Deltacloud
  module Drivers
    module RHEVM

class RHEVMDriver < Deltacloud::BaseDriver

  SCRIPT_DIR = File.dirname(__FILE__) + '/scripts'
  CONFIG = YAML.load_file(File.dirname(__FILE__) + '/../../../../config/rhevm_config.yml')
  SCRIPT_DIR_ARG = '"' + SCRIPT_DIR + '"'
  DELIM_BEGIN="<_OUTPUT>"
  DELIM_END="</_OUTPUT>"
  POWERSHELL="c:\\Windows\\system32\\WindowsPowerShell\\v1.0\\powershell.exe"
  NO_OWNER=""

  feature :instances, :user_name

  #
  # Execute a Powershell command, and convert the output
  # to YAML in order to get back an array of maps.
  #
  def execute(credentials, command, *args)
    args = args.to_a
    argString = genArgString(credentials, args)
    puts argString
    outputMaps = {}
    output = `#{POWERSHELL} -command "&{#{File.join(SCRIPT_DIR, command)} #{argString}; exit $LASTEXITCODE}`
    exitStatus = $?.exitstatus
    puts(output)
    puts("EXITSTATUS #{exitStatus}")
    st = output.index(DELIM_BEGIN)
    if (st)
      st += DELIM_BEGIN.length
      ed = output.index(DELIM_END)
      output = output.slice(st, (ed-st))
      # Lets make it yaml
      output.strip!
      if (output.length > 0)
        outputMaps = YAML.load(self.toYAML(output))
      end
    end
    outputMaps
  end

  def genArgString(credentials, args)
    commonArgs = [SCRIPT_DIR_ARG, credentials.user, credentials.password, CONFIG["domain"]]
    commonArgs.concat(args)
    commonArgs.join(" ")
  end

  def toYAML(output)
    yOutput = "- \n" + output
    yOutput.gsub!(/^(\w*)[ ]*:[ ]*([A-Z0-9a-z._ -:{}]*)/,' \1: "\2"')
    yOutput.gsub!(/^[ ]*$/,"- ")
    puts(yOutput)
    yOutput
  end

  def statify(state)
    st = state.nil? ? "" : state.upcase()
    case st
    when "UP"
      "RUNNING"
    when "DOWN"
      "STOPPED"
    when "POWERING UP"
      "PENDING"
  end

  define_hardware_profile 'rhevm'

  #
  # Realms
  #

  def realms(credentials, opts=nil)
    domains = execute(credentials, "storageDomains.ps1")
    if (!opts.nil? && opts[:id])
        domains = domains.select{|d| opts[:id] == d["StorageId"]}
    end

    realms = []
    domains.each do |dom|
      realms << domain_to_realm(dom)
    end
    realms
  end

  def domain_to_realm(dom)
    Realm.new({
      :id => dom["StorageId"],
      :name => dom["Name"],
      :limit => dom["AvailableDiskSize"]
    })
  end



  #
  # Images
  #

  def images(credentials, opts=nil )
    templates = []
    if (opts.nil?)
      templates = execute(credentials, "templates.ps1")
    else
      if (opts[:id])
        templates = execute(credentials, "templateById.ps1", opts[:id])
      end
    end
    images = []
    templates.each do |templ|
      images << template_to_image(templ)
    end
    images
  end

  def template_to_image(templ)
    Image.new({
      :id => templ["TemplateId"],
      :name => templ["Name"],
      :description => templ["Description"],
      :architecture => templ["OperatingSystem"],
      :owner_id => NO_OWNER,
      :mem_size_md => templ["MemSizeMb"],
      :instance_count => templ["ChildCount"],
      :state => templ["Status"],
      :capacity => templ["SizeGB"]
    })
  end

  #
  # Instances
  #

  define_instance_states do
    start.to(:stopped)            .on( :create )

    pending.to(:shutting_down)    .on( :stop )
    pending.to(:running)          .automatically

    running.to(:pending)          .on( :reboot )
    running.to(:shutting_down)    .on( :stop )

    shutting_down.to(:stopped)    .automatically
    stopped.to(:pending)          .on( :start )
    stopped.to(:finish)           .on( :destroy )
  end

  def instances(credentials, opts=nil)
    vms = []
    if (opts.nil?)
      vms = execute(credentials, "vms.ps1")
    else
      if (opts[:id])
        vms = execute(credentials, "vmById.ps1", opts[:id])
      end
    end
    instances = []
    vms.each do |vm|
      instances << vm_to_instance(vm)
    end
    instances = filter_on( instances, :id, opts )
    instances = filter_on( instances, :state, opts )
    instances
  end

  def vm_to_instance(vm)
    Instance.new({
      :id => vm["VmId"],
      :description => vm["Description"],
      :name => vm["Name"],
      :architecture => vm["OperatingSystem"],
      :owner_id => NO_OWNER,
      :image_id => vm["TemplateId"],
      :state => statify(vm["Status"]),
      :instance_profile => InstanceProfile.new("rhevm"),
      :actions => instance_actions_for(statify(vm["Status"])),
    })
  end

  def start_instance(credentials, image_id)
    vm = execute(credentials, "startVm.ps1", image_id)
    vm_to_instance(vm[0])
  end

  def stop_instance(credentials, image_id)
    vm = execute(credentials, "stopVm.ps1", image_id)
    vm_to_instance(vm[0])
  end

  def create_instance(credentials, image_id, opts)
    name = opts[:name]
    name = "Inst-#{rand(10000)}" if (name.nil? or name.empty?)
    realm_id = opts[:realm_id]
    if (realm_id.nil?)
        realms = filter_on(realms(credentials, opts), :name, :name => "data")
        puts realms[0]
        realm_id = realms[0].id
    end
    vm = execute(credentials, "addVm.ps1", image_id, name, realm_id)
    vm_to_instance(vm[0])
  end

  def reboot_instance(credentials, image_id)
    vm = execute(credentials, "rebootVm.ps1", image_id)
    vm_to_instance(vm[0])
  end

  def destroy_instance(credentials, image_id)
    vm = execute(credentials, "deleteVm.ps1", image_id)
    vm_to_instance(vm[0])
  end

  #
  # Storage Volumes
  #

  def storage_volumes(credentials, ids=nil)
    volumes = []
    volumes
  end

  #
  # Storage Snapshots
  #

  def storage_snapshots(credentials, ids=nil)
    snapshots = []
    snapshots
  end

end

    end
  end
end
