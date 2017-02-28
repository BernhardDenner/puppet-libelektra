# encoding: UTF-8
##
# @file
#
# @brief Ruby provider for type kdbkey for managing libelektra keys
#
# @copyright BSD License (see LICENSE or http://www.libelektra.org)
#
#

module Puppet
  Type.type(:kdbkey).provide :ruby, :parent => Puppet::Provider::KdbKeyCommon do
    desc "kdb through libelektra Ruby API"

    # static class var for checking if we are able to use this provider
    @@have_kdb = true
    @@is_fake_ks = false

    begin
      # load libelektra Ruby binding extension
      require 'kdb'
    rescue LoadError
      @@have_kdb = false
    end

    # make this provider default for Linux systems
    defaultfor :kernel => :Linux
    # if we can load the 'kdb' extension
    confine :true => @@have_kdb

    if @@have_kdb
      Puppet.debug "kdbkey/ruby: open kdb db"
      @@db = Kdb.open
      @@ks = Kdb::KeySet.new
      @@db.get @@ks, "/"
    end

    # just used during testing to inject a mock
    def self.use_fake_ks(ks)
      @@ks = ks
      @@is_fake_ks = true
    end

    # allow access to internal key, used during testing
    attr_reader :resource_key

    def create
      #puts "ruby create #{@resource[:name]}"
      @resource_key = Kdb::Key.new @resource[:name], value: @resource[:value]
      self.check= @resource[:check] unless @resource[:check].nil?
      self.metadata= @resource[:metadata] unless @resource[:metadata].nil?
      self.comments= @resource[:comments] unless @resource[:comments].nil?
      @@ks << @resource_key
    end

    def destroy
      #puts "ruby destroy #{@resource[:name]}"
      @@ks.delete @resource[:name] unless @resource_key.nil?
    end

    # is called first for each managed resource
    # stores the queried key for later modifications
    def exists?
      Puppet.debug "kdbkey/ruby exists? #{@resource[:name]}"
      #puts "kdbkey/ruby @should: #{value(:metadata)}"
      @resource_key = @@ks.lookup @resource[:name]
      return !@resource_key.nil?
    end

    def value
      #puts "getting value #{@resource[:name]}"
      return @resource_key.value unless @resource_key.nil?
    end

    def value=(value)
      #puts "setting value of #{@resource[:name]} to #{value}"
      @resource_key.value= value unless @resource_key.nil?
    end

    def metadata
      #key.meta.to_h unless key.nil? ruby 1.9 does not have Enumerable.to_h :(
      res = Hash.new
      @resource_key.meta.each do |e|
        next if skip_this_metakey? e.name, true

        # if purge_meta_keys is NOT set to true, remove all unspecified keys
        # otherwise, Puppet will think we have to change something, so just
        # keep those, which might have to be changed
        unless @resource.purge_meta_keys? or @resource[:metadata].nil?
          next unless @resource[:metadata].include? e.name
        end

        res[e.name] = e.value
      end unless @resource_key.nil?

      return res
    end

    def metadata=(value)
      # update metadata
      value.each { |k, v|
        @resource_key.set_meta k, v
      } unless @resource_key.nil?

      # do we have to purge all unspecified keys?
      if @resource.purge_meta_keys?
        @resource_key.meta.each do |metakey|
          next if skip_this_metakey? metakey.name

          @resource_key.del_meta metakey.name unless value.include? metakey.name
        end
      end
    end

    def comments
      comments = ""
      first = true # used for splitting lines
      # search for all meta keys which names starts with 'comments/#'
      # and concat its values line by line
      @resource_key.meta.each do |e|
        if e.name.start_with? "comments/#"
          comments << "\n" unless first
          comments << e.value.sub(/^# ?/, '')
          first = false
        end
      end
      return comments
    end

    def comments=(value)
      # split specified comment into lines
      comment_lines = value.split "\n"
      # if we do not have any comments, remove them
      if comment_lines.size == 0
        @resource_key.del_meta "comments"
      else
        @resource_key.set_meta "comments", "##{comment_lines.size - 1}"
      end

      # update all comment lines
      comment_lines.each_with_index do |line, index|
        @resource_key.set_meta "comments/##{index}", "##{line}"
      end

      # iterate over all meta keys and remove all comment keys which
      # represent a comment line, which does not exist any more
      @resource_key.meta.each do |e|
        if e.name.match(/^comments\/#(\d+)$/)
          index = $~[1].to_i
          if comment_lines[index].nil?
            @resource_key.del_meta e.name
          end
        end
      end
    end

    def check
      spec_hash = {}
      spec_key = @@ks.lookup get_spec_key_name
      unless spec_key.nil?
        spec_key.meta.each do |m|
          if /^check\/(.*)$/ =~ m.name
            check_name = $1
            if /^(\w+)\/#\d+$/ =~ check_name
              spec_hash[$1] = [] unless spec_hash[$1].is_a? Array
              spec_hash[$1] << m.value
            else
              spec_hash[check_name] = m.value
            end
          end
        end
      end
      # special case: if we get just one key and its value
      # is "", return this as a string
      if spec_hash.size == 1 and spec_hash.values[0] == ""
        spec_hash = spec_hash.keys[0]
      end
      Puppet.debug "having spec: #{spec_hash}"
      return spec_hash
    end

    def check=(value)
      Puppet.debug "setting spec: #{value}"
      spec_key = Kdb::Key.new get_spec_key_name

      if @@ks.lookup(spec_key).nil?
        @@ks << spec_key
      else
        spec_key = @@ks.lookup spec_key
      end

      spec_to_set = specified_checks_to_meta value

      # set meta data on spec_key
      spec_to_set.each do |spec_name, spec_value|
        spec_key[spec_name] = spec_value
      end

      # remove all not specified meta keys from spec_key starting with 'check'
      spec_key.meta.each do |e|
        if e.name.start_with? "check" and !spec_to_set.include? e.name
          spec_key.del_meta e.name
        end
      end
    end


    # flush is call if a resource was modified
    # thus this method is perfectly suitable for our db.set method which will
    # finally bring the changes to disk
    def flush
      unless @@is_fake_ks
        Puppet.debug "kdbkey/ruby: flush #{@resource[:name]}"
        @@db.set @@ks, "/"
      end
    end

    # this is the provider de-init hook
    # so lets close our kdb db now
    def self.post_resource_eval
      Puppet.debug "kdbkey/ruby: closing kdb db"
      @@db.close if @@have_kdb
    end

  end
end
