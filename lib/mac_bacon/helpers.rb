require 'tmpdir'

module Bacon
  module Helpers
    # A cache of XIB files converted to the compiled NIB format.
    def self.converted_xibs
      @converted_xibs ||= {}
    end

    # Checks if the given file path points to a compiled NIB file and if so
    # returns the same path. If it's a XIB file it will be compiled with
    # +ibtool+ as a tmp file and the new path will be returned instead.
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

    # Loads the NIB at +nib_path+ with the specified +files_owner+ as the
    # <tt>File's owner</tt>.
    #
    # All top-level objects in the NIB are returned as an array, although
    # you'll generally just deal with the controller, in which case you can
    # ignore them.
    #
    #   describe "PreferencesController" do
    #     before do
    #       @controller = PreferencesController.new
    #       nib_path = File.join(SRC_ROOT, 'app/views/PreferencesWindow.xib')
    #       @top_level_objects = load_nib(nib_path, @controller)
    #     end
    #
    #     # tests...
    #
    #   end
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
