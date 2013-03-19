#!/usr/bin/env ruby
# -*- mode: ruby; tab-width: 4; indent-tabs-mode: nil -*-
#
# FIXME
# * Support .erb templates.
# * Pass calling PID+UID, and maybe the process-title, to pinentry via PINENTRY_USER_DATA
# * Configuration file

require 'pathname'
require 'rfuse'

class PassFS
    HOME  = Pathname('~/.passfs').expand_path
    STORE = HOME + 'store'
    MOUNT = HOME + 'mount'

    def self.mount
        # noauto_cache
        args = ['-onoubc', '-olocal', '-onobrowse', "-ovolname=#{ENV['USER']}-passfs"]
        fs = PassFS::FuseFS.new
        fo = RFuse::FuseDelegator.new(fs, MOUNT, *args)

        if fo.mounted?
            #Process.daemon

            Signal.trap("TERM") { print "Caught TERM\n" ; fo.exit }
            Signal.trap("INT") { print "Caught INT\n"; fo.exit }

            begin
                fo.loop
            rescue
                print "Error:" + $!.to_s
            ensure
                fo.unmount if fo.mounted?
                print "Unmounted #{ARGV[0]}\n"
            end
        end
    end

    def self.setup
        [HOME, STORE, MOUNT].each { |dir| Dir.mkdir(dir) unless Dir.exist?(dir) }

        # FIXME: no. replace with config-file, and set gpg-id there.
        unless File.exist?(STORE + '.gpg-id')
            puts "Initializing new password file-store."
            print "Please enter GPG id: "
            gpgid = $stdin.readline

            system({"PASSWORD_STORE_DIR" => STORE.to_s}, "pass init #{gpgid}")
        end
    end

    def self.decrypt(file)
        pipe = IO.popen(%w(gpg2 --quiet --yes --batch --decrypt) + [file.to_s])
        data = pipe.read
        pipe.close
        data
    end

    def self.add(files)
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

            dest = STORE + file.relative_path_from(Pathname(ENV['HOME']))
            dest.dirname.mkdir unless dest.dirname.exist?
            system(*%w(gpg2 --encrypt --quiet --yes --batch --recipient), "kvs@binarysolutions.dk", '--output', dest.to_s, file.to_s)
            # FIXME: add symlink in original files' place
        end
    end

    def remove(files)
        files.each do |file|
        end
    end

    class FuseFS
        def _stat(path)
            fstat = path.stat

            if path.directory?
                RFuse::Stat.directory(fstat.mode, :uid => fstat.uid, :gid => fstat.gid, :atime => fstat.atime, :mtime => fstat.mtime, :size => fstat.size)
            else
                RFuse::Stat.file(fstat.mode, :uid => fstat.uid, :gid => fstat.gid, :atime => fstat.atime, :mtime => fstat.mtime, :size => fstat.size)
            end
        end

        # The new readdir way, c+p-ed from getdir
        def readdir(ctx, path, filler, offset, ffi)
            path = path.sub(/^\//, '')
            begin
                (STORE + path).entries.each do |entry|
                    next if entry == Pathname('.') or entry == Pathname('..')
                    filler.push(entry.to_s, _stat(STORE + path + entry), 0)
                end
            rescue Errno::ENOTDIR
                raise Errno::ENOTDIR.new(path)
            end
        end

        def getattr(ctx, path)
            path = path.sub(/^\//, '')
            _stat(STORE + path)
        end

        def read(ctx, path, size, offset, fi)
            path = path.sub(/^\//, '')
            puts "pid #{ctx.pid}, uid #{ctx.uid}, gid #{ctx.gid} reading #{path}"

            store_path = STORE + path

            if store_path.directory?
                raise Errno::EISDIR.new(path)
            elsif store_path.file?
                content = PassFS.decrypt(store_path)
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
    PassFS.mount
when 'umount'
    PassFS.umount
when 'add'
    PassFS.add(ARGV)
when 'remove'
    PassFS.remove(ARGV)
when 'setup'
    PassFS.setup
else
    $stderr.puts "Unknown command."
    exit 1
end
