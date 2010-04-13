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


class BaseModel

  def initialize(init=nil)
    if ( init )
      @id=init[:id]
      init.each{|k,v|
        self.send( "#{k}=", v ) if ( self.respond_to?( "#{k}=" ) )
      }
    end
  end

  def self.attr_accessor(*vars)
    @attributes ||= [:id]
    @attributes.concat vars
    super
  end

  def self.attributes
    @attributes
  end

  def attributes
    self.class.attributes
  end

  def id
    @id
  end

  def to_hash
    out = {}
    self.attributes.each { |attribute| out.merge!({ attribute => self.send(:"#{attribute}") } ) }
    out
  end

  def to_json
    self.to_hash.to_json
  end

end
