#!/usr/bin/env ruby
# -*- mode: ruby; tab-width: 4; indent-tabs-mode: nil -*-
#
# FIXME
# * Support .erb templates.
# * Pass calling PID+UID, and maybe the process-title, to pinentry via PINENTRY_USER_DATA
# * Configuration file

require 'pathname'
require 'rfuse'
require 'yaml'
require 'ostruct'

class PassFS
    attr_reader :config

    def initialize
        root = Pathname("~/.passfs").expand_path
        config_file = root + 'config.yml'

        if !config_file.file?
            puts "* Creating a new config file for you."
            print "Please enter the GnuPG key to encrypt files for: "
            keyid = $stdin.readline.chomp

            root.mkdir unless root.directory?
            config_file.open('w') do |file|
                file.write <<-EOT.gsub(%r{^\s+}, '').chomp
                    ---
                    :store: ~/.passfs/store
                    :mount: ~/.passfs/mount
                    :keyid: #{keyid}
                    :daemonize?: true
                EOT
                file.puts
            end
        end

        @config = OpenStruct.new(YAML.load_file(config_file))
        @config.store = Pathname(@config.store).expand_path
        @config.mount = Pathname(@config.mount).expand_path
        @config.store.mkdir unless @config.store.directory?
        @config.mount.mkdir unless @config.mount.directory?
    end

    def mount
        args = ['-onoubc', '-olocal', '-onobrowse', "-ovolname=#{ENV['USER']}-passfs"]
        fs = PassFS::FuseFS.new(config)
        fo = RFuse::FuseDelegator.new(fs, config.mount, *args)

        if fo.mounted?
            Process.daemon if config.daemonize?

            Signal.trap('TERM') { fo.exit }
            Signal.trap('INT')  { fo.exit }

            begin
                fo.loop
            rescue
                puts "Error:" + $!.to_s
            ensure
                fo.unmount if fo.mounted?
                puts "Unmounted #{config.mount}"
            end
        end
    end

    def umount
        system 'umount', config.mount.to_s
    end

    def add(files)
        files.each do |file|
            file = Pathname(file).expand_path
            unless file.to_s.match(/^#{ENV['HOME']}/)
                puts "File not in ~: #{file}"
                next
            end

            unless file.exist?
                puts "No such file or directory: #{file}"
                next
            end

            relative_path = file.relative_path_from(Pathname(ENV['HOME']))
            dest = config.store + relative_path
            dest.dirname.mkpath unless dest.dirname.exist?
            if system(*%w(gpg2 --encrypt --quiet --yes --batch --recipient), "kvs@binarysolutions.dk", '--output', dest.to_s, file.to_s)
                File.open("#{dest.to_s}.size", 'w') { |f| f.write file.size }
                file.unlink
                file.make_symlink(config.mount + relative_path)
            else
                $stderr.puts "* Something went wrong"
                exit 1
            end
        end
    end

    def remove(files)
        files.each do |file|
            file = Pathname(file).expand_path
            if file.symlink? && file.readlink.to_s.match(%r{^#{config.mount.to_s}})
                content = file.read
                src = file.readlink.to_s.sub(%r{^#{config.mount.to_s}}, config.store.to_s)

                file.unlink
                file.open('w') { |f| f.write content }
                File.unlink(src)
                File.unlink("#{src}.size")
            else
                $stderr.puts "Not a file protected by passfs"
                exit 1
            end

        end
    end

    class FuseFS
        attr_reader :config

        def initialize(config)
            @config = config
        end

        def _decrypt(file)
            pipe = IO.popen(%w(gpg2 --quiet --yes --batch --decrypt) + [file.to_s])
            data = pipe.read
            pipe.close
            data
        end

        # The new readdir way, c+p-ed from getdir
        def readdir(ctx, path, filler, offset, ffi)
            path = Pathname(path).relative_path_from(Pathname('/'))

            begin
                (config.store + path).entries.each do |entry|
                    entry = entry.to_s

                    next if entry == '.' or entry == '..' or entry.end_with?('.size')
                    filler.push(entry, getattr(ctx, path + entry), 0)
                end
            rescue Errno::ENOTDIR
                raise Errno::ENOTDIR.new(path)
            end
        end

        def getattr(ctx, path)
            path = Pathname(path).relative_path_from(Pathname('/')) unless Pathname(path).relative?
            path = config.store + path
            fstat = path.stat

            if path.directory?
                RFuse::Stat.directory(fstat.mode, :uid => fstat.uid, :gid => fstat.gid, :atime => fstat.atime, :mtime => fstat.mtime, :size => fstat.size)
            else
                size = Integer(File.read("#{path.to_s}.size"))
                RFuse::Stat.file(fstat.mode, :uid => fstat.uid, :gid => fstat.gid, :atime => fstat.atime, :mtime => fstat.mtime, :size => size)
            end
        end

        def read(ctx, path, size, offset, fi)
            path = path.sub(/^\//, '')

            store_path = config.store + path

            if store_path.directory?
                raise Errno::EISDIR.new(path)
            elsif store_path.file?
                content = _decrypt(store_path)
                content[offset..offset + size - 1]
            else
                raise Errno::ENOENT
            end
        end

        # Some random numbers to show with df command
        def statfs(ctx, path)
            s = RFuse::StatVfs.new()
            s.f_bsize    = 1024
            s.f_frsize   = 1024
            s.f_blocks   = 1000000
            s.f_bfree    = 500000
            s.f_bavail   = 990000
            s.f_files    = 10000
            s.f_ffree    = 9900
            s.f_favail   = 9900
            s.f_fsid     = 23423
            s.f_flag     = 0
            s.f_namemax  = 10000
            return s
        end
    end
end

case ARGV.shift
when 'mount'
    PassFS.new.mount
when 'umount'
    PassFS.new.umount
when 'protect'
    PassFS.new.add(ARGV)
when 'unprotect'
    PassFS.new.remove(ARGV)
when 'setup'
    PassFS.new
else
    $stderr.puts "Unknown command."
    exit 1
end
