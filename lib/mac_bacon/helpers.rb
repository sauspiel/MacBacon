require 'tmpdir'

module Bacon
  module Helpers
    def self.converted_xibs
      @converted_xibs ||= {}
    end

    def self.ensure_nib(path)
      if File.extname(path) == '.xib'
        if cached = Helpers.converted_xibs[path]
          cached
        else
          xib_path, nib_path = path, File.join(Dir.tmpdir, "#{Time.now.to_i}.nib")
          unless system("/usr/bin/ibtool '#{xib_path}' --compile '#{nib_path}'")
            raise "Unable to convert XIB (to temporary NIB) at path `#{xib_path}'"
          end
          Helpers.converted_xibs[xib_path] = nib_path
          nib_path
        end
      else
        path
      end
    end

    def load_nib(nib_path, files_owner)
      nib_path = Helpers.ensure_nib(nib_path)
      url = NSURL.fileURLWithPath(nib_path)
      nib = NSNib.alloc.initWithContentsOfURL(url)
      top_level_objects = []
      nameTable = {
        NSNibOwner => files_owner,
        NSNibTopLevelObjects => top_level_objects
      }
      nib.instantiateNibWithExternalNameTable(nameTable)
      top_level_objects
    end
  end

  class Context
    include Helpers
  end
end
