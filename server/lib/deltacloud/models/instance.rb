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


class Instance < BaseModel

  attr_accessor :owner_id
  attr_accessor :image_id
  attr_accessor :name
  attr_accessor :realm_id
  attr_accessor :state
  attr_accessor :actions
  attr_accessor :public_addresses
  attr_accessor :private_addresses
  attr_accessor :instance_profile
  attr_accessor :launch_time
 def initialize(init=nil)
   super(init)
   self.actions = [] if self.actions.nil?
   self.public_addresses = [] if self.public_addresses.nil?
   self.private_addresses = [] if self.private_addresses.nil?
  end
end
