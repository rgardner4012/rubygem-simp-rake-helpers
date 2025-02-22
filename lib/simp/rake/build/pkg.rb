#!/usr/bin/rake -T

require 'simp/yum'
require 'simp/rake/pkg'
require 'simp/rake/build/constants'
require 'simp/rake/build/rpmdeps'

module Simp; end
module Simp::Rake; end
module Simp::Rake::Build

  class Pkg < ::Rake::TaskLib
    include Simp::Rake
    include Simp::Rake::Build::Constants

    def initialize( base_dir )
      init_member_vars( base_dir )

      @cpu_limit = get_cpu_limit
      @verbose = ENV.fetch('SIMP_PKG_verbose','no') == 'yes'
      @rpm_build_metadata = 'last_rpm_build_metadata.yaml'
      @rpm_dependency_file = File.join(@base_dir, 'build', 'rpm', 'dependencies.yaml')
      @build_keys_dir = ENV.fetch('SIMP_PKG_build_keys_dir', File.join(@base_dir, '.dev_gpgkeys'))
      @long_gpg_socket_err_msg = <<~MSG
        If the problem is 'socket name <xxx> is too long', use SIMP_PKG_build_keys_dir
        to override
        #{@build_keys_dir}
        with a shorter path. The socket name must be < 108 characters.

      MSG
      # nil = default not set; use local preference
      @fetch_published_rpm_default = ENV['SIMP_PKG_fetch_published_rpm'] ? (
        ENV['SIMP_PKG_fetch_published_rpm'] =~ /\A(yes|true)\Z/i ? true : false
      ) : nil

      define_tasks
    end

    def define_tasks
      namespace :pkg do
        ##############################################################################
        # Main tasks
        ##############################################################################

        # Have to get things set up inside the proper namespace
        task :prep,[:method] do |t,args|

          # This doesn't get caught for things like 'rake clean'
          if $simp6 && $simp6_build_dir
            @build_dir = $simp6_build_dir || @distro_build_dir
            @dvd_src = File.join(@build_dir, File.basename(@dvd_src))
          end

          args.with_defaults(:method => 'tracking')

          @build_dirs = {
            :modules => get_module_dirs(args[:method]),
            :aux => [
              # Anything in here gets built!
              "#{@src_dir}/assets/*"
            ],
            :doc => "#{@src_dir}/doc"
          }

          @build_dirs[:aux].map!{|dir| dir = Dir.glob(dir)}
          @build_dirs[:aux].flatten!
          @build_dirs[:aux].delete_if{|f| !File.directory?(f)}

          @pkg_dirs = {
            :simp => "#{@build_dir}/SIMP"
          }
        end

        clean_failures = []
        clean_failures_lock = Mutex.new

        task :clean => [:prep] do |t,args|
          @build_dirs.each_pair do |k,dirs|
            Parallel.map(
              Array(dirs),
              :in_processes => @cpu_limit,
              :progress => t.name
            ) do |dir|
              Dir.chdir(dir) do
                begin
                  rake_flags = Rake.application.options.trace ? '--trace' : ''
                  %x{rake clean #{rake_flags}}
                  clean_failures_lock.synchronize do
                    clean_failures << dir unless $?.success?
                  end
                rescue Exception => e
                  clean_failures_lock.synchronize do
                    clean_failures << dir
                  end
                  raise Parallel::Kill
                end
              end
            end
          end

          unless clean_failures.empty?
            fail(%(Error: The following directories had failures in #{task.name}:\n  * #{clean_failures.join("\n  * ")}))
          end
        end

        task :clobber => [:prep] do |t,args|
          @build_dirs.each_pair do |k,dirs|
            Parallel.map(
              Array(dirs),
              :in_processes => @cpu_limit,
              :progress => t.name
            ) do |dir|
              Dir.chdir(dir) do
                rake_flags = Rake.application.options.trace ? '--trace' : ''
                sh %{rake clobber #{rake_flags}}
              end
            end
          end
        end

        desc <<~DESC
          Prepare a GPG signing key to sign build packages

            * :key - the name of the build keys subdirectory to prepare
              (defaults to 'dev')

              - The default build keys directory is
                `#{@build_keys_dir}`


          When :key is `dev`, a temporary signing key is created, if needed:

            * A 14-day `dev` key will be created if none exists or the existing
              key has expired.  This includes creating
              - A `dev` directory in the build keys directory
              - gpg-agent assets to create/update the key within that `dev`
                directory

          When :key is *not* `dev`, the logic is much stricter:

            - You must already have created the `<:key>` subdirectory within
              the build keys directory and placed a valid GPG signing key and
              requisite gpg-agent assets to access the key within the directory.
            - If the directory or key are missing, the task will fail.

          ENV vars:
            - Set `SIMP_PKG_verbose=yes` to report file operations as they happen.
            - Set `SIMP_PKG_build_keys_dir` to override the default build keys path.
        DESC
        task :key_prep,[:key] => [:prep] do |t,args|
          args.with_defaults(:key => 'dev')
          key = args.key
          key_dir = File.join(@build_keys_dir,key)
          dvd_dir = @dvd_src

          FileUtils.mkdir_p @build_keys_dir

          Dir.chdir(@build_keys_dir) do
            if key == 'dev'
              require 'simp/local_gpg_signing_key'

              begin
                Simp::LocalGpgSigningKey.new(key_dir,{verbose: @verbose}).ensure_key
              rescue Exception => e
                raise("#{e.message}\n\n#{@long_gpg_socket_err_msg}")
              end
            else
              unless File.directory?(key_dir)
                fail("Could not find GPG keydir '#{key_dir}' in '#{Dir.pwd}'")
              end
            end

            Dir.chdir(key_dir) do
              rpm_build_keys = Dir.glob('RPM-GPG-KEY-*')
              if rpm_build_keys.empty?
                fail("Could not find any RPM-GPG-KEY-* files in '#{key_dir}'")
              end

              # Copy development keys into the root of the ISO for convenience
              if key == 'dev'
                unless File.directory?(dvd_dir)
                  fail("Could not find DVD ISO root directory '#{dvd_dir}'")
                end

                rpm_build_keys.each do |gpgkey|
                  cp(gpgkey, dvd_dir, :verbose => @verbose)
                end
              # Otherwise, make sure it isn't present for the build
              else
                Dir[File.join(dvd_dir,'RPM-GPG-KEY-SIMP*')].each do |to_del|
                  rm(to_del)
                end
              end
            end
          end
        end

        def populate_rpm_dir(rpm_dir)
          srpm_dir = File.join(File.dirname(rpm_dir), 'SRPMS')

          FileUtils.mkdir_p(rpm_dir)
          FileUtils.mkdir_p(srpm_dir)

          rpm_metadata = %x(find -P #{@src_dir} -xdev -type f -name #{@rpm_build_metadata}).lines.map(&:strip).sort

          fail("No #{@rpm_build_metadata} files found under #{@src_dir}") if rpm_metadata.empty?

          rpm_metadata.each do |mf|
            metadata = YAML.load_file(mf)
            rpms = metadata['rpms']
            srpms = metadata['srpms']

            fail("No RPMs found at #{rpm_dir}") if (rpms.nil? || rpms.empty?)

            have_signed_rpm = false
            Dir.chdir(rpm_dir) do
              rpms.each_key do |rpm|
                if @verbose
                  puts "Copying #{rpm} to #{rpm_dir}"
                end

                arch = rpms[rpm]['metadata'][:arch]
                FileUtils.mkdir_p(arch)

                FileUtils.cp(rpms[rpm]['path'], arch)

                if rpms[rpm][:signature]
                  have_signed_rpm = true
                end
              end
            end

            Dir.chdir(srpm_dir) do
              srpms.each_key do |srpm|
                if have_signed_rpm && !srpms[srpm][:signature]
                  if @verbose
                    puts "Found signed RPM - skipping copy of '#{srpm}'"
                  end

                  next
                end

                if @verbose
                  puts "Copying '#{srpm}' to '#{srpm_dir}'"
                end

                arch = srpms[srpm]['metadata'][:arch]
                FileUtils.mkdir_p(arch)

                FileUtils.cp(srpms[srpm]['path'], arch)
              end
            end
          end
        end


=begin
        desc <<~DESC
          Build the entire SIMP release.

            * :docs - Build the docs. Set this to false if you wish to skip building the docs.
            * :key - The GPG key to sign the RPMs with. Defaults to 'dev'.

            ENV vars:
              - Set `SIMP_PKG_verbose=yes` to report file operations as they happen.
              - Set `SIMP_YUM_makecache=no` if you do NOT want to rebuild the
                build-specific YUM cache
        DESC
=end
        task :build,[:docs,:key] => [:prep,:key_prep] do |t,args|
          args.with_defaults(:key => 'dev')
          args.with_defaults(:docs => 'true')

          check_dvd_env

          get_yum_helper

          Rake::Task['pkg:aux'].invoke
          if "#{args.docs}" == 'true'
            Rake::Task['pkg:doc'].invoke
          end
          Rake::Task['pkg:modules'].invoke

          populate_rpm_dir(@rpm_dir)

          Rake::Task['pkg:signrpms'].invoke(args[:key])
        end

        desc <<~DESC
          Build the Puppet module RPMs.

            * :method - The Puppetfile from which the repository information
                        should be read. Defaults to 'tracking'

            ENV vars:
              - Set `SIMP_PKG_verbose=yes` to report file operations as they happen.
        DESC
        task :modules,[:method] => [:prep] do |t,args|
          build(@build_dirs[:modules],t)
        end

        desc <<~DESC
          Build a single Puppet Module RPM.

            * :name   - The path, or name, of the module to build. If a name is
                        given, the Puppetfile.<method> will be used to find the
                        module.
                        Note: This is the *short* name. So, to build
                        puppetlabs-stdlib, you would just enter 'stdlib'
            * :method - The Puppetfile from which the repository information should be read. Defaults to 'tracking'

            ENV vars:
              - Set `SIMP_PKG_verbose=yes` to report file operations as they happen.
              - Set `SIMP_YUM_makecache=no` if you do NOT want to rebuild the
                build-specific YUM cache
        DESC
        task :single,[:name,:method] => [:prep] do |t,args|
          fail("You must pass :name to '#{t.name}'") unless args[:name]

          mod_path = File.absolute_path(args[:name])
          get_yum_helper

          if args[:name].include?('/')
            fail("'#{args[:name]}' does not exist!") unless File.directory?(mod_path)
          else
            load_puppetfile(args[:method])
            local_module = puppetfile.modules.select{|m| m[:name] == args[:name]}.first

            unless local_module
              fail("'#{args[:name]}' was not found in the Puppetfile")
            end

            mod_path = local_module[:path]
          end

          build(Array(mod_path), t)

          puts("Your packages can be found in '#{mod_path}/dist'")
        end

        desc <<~DESC
          Build the SIMP non-module RPMs.

            ENV vars:
              - Set `SIMP_PKG_verbose=yes` to report file operations as they happen.
        DESC
        task :aux => [:prep]  do |t,args|
          build(@build_dirs[:aux],t)
        end

        desc <<~DESC
          Build the SIMP documentation.

            ENV vars:
              - Set `SIMP_PKG_verbose=yes` to report file operations as they happen.
        DESC
        task :doc => [:prep] do |t,args|
          # Need to make sure that the docs have the version updated
          # appropriately prior to building

          Dir.chdir(@build_dirs[:doc]) do
            sh %{rake munge:prep}
          end

          build(@build_dirs[:doc],t)
        end

        desc <<~DESC
          Sign a set of RPMs.

            Signs any unsigned RPMs in the specified directory
              * :key - The key directory to use under the build keys directory
                * key defaults to 'dev'
                * build keys directory defaults to
                  `#{@build_keys_dir}`
              * :rpm_dir - A directory containing RPM files to sign. Will recurse!
                * Defaults to #{File.join(File.dirname(@rpm_dir), '*RPMS')}
              * :force - Force rpms that are already signed to be resigned
                * Defaults to 'false', can be enabled with 'true'
              * :digest_algo - Digest algorithm to be used when signing the RPMs
                * Defaults to 'sha256'

          ENV vars:
            * Set `SIMP_RPM_verbose=yes` to report RPM operations as they happen.
            * Set `SIMP_PKG_build_keys_dir` to override the default build keys path.
            * Set `SIMP_PKG_rpmsign_timeout` to override the maximum time in seconds
              to wait for an individual RPM signing operation to complete.
              - Defaults to 60 seconds.
        DESC
        task :signrpms,[:key,:rpm_dir,:force,:digest_algo] => [:prep,:key_prep] do |t,args|
          require 'simp/rpm_signer'

          args.with_defaults(:key => 'dev')
          args.with_defaults(:rpm_dir => File.join(File.dirname(@rpm_dir), '*RPMS'))
          args.with_defaults(:force => 'false')
          args.with_defaults(:digest_algo => 'sha256')

          force = (args[:force].to_s == 'false' ? false : true)
          timeout = ENV['SIMP_PKG_rpmsign_timeout'] ? ENV['SIMP_PKG_rpmsign_timeout'].to_i : 60

          opts = {
            :digest_algo        => args[:digest_algo],
            :force              => force,
            :max_concurrent     => @cpu_limit,
            :progress_bar_title => t.name,
            :timeout_seconds    => timeout,
            :verbose            => @verbose
          }

          results = nil
          begin
            results = Simp::RpmSigner.sign_rpms(
              args[:rpm_dir],
              File.join(@build_keys_dir, args[:key]),
              opts
            )
          rescue Exception => e
            raise("#{e.message}\n\n#{@long_gpg_socket_err_msg}")
          end

          if results
            successes = results.select { |rpm,status| status == :signed }
            failures = results.select { |rpm,status| status == :unsigned }
            already_signed = results.select { |rpm,status| status == :skipped_already_signed }

            if opts[:verbose]
              puts
              puts 'Summary'
              puts '======='
              puts "# RPMs already signed:      #{already_signed.size}"
              puts "# RPMs successfully signed: #{successes.size}"
              puts "# RPM signing failures:     #{failures.size}"
              puts
            end

            if !failures.empty?
              if ((results.size - already_signed.size) == (failures.size))
                detail = already_signed.empty? ? '' : 'unsigned '
                raise("ERROR: Failed to sign all #{detail}RPMs in #{args[:rpm_dir]}")
              else
                err_msg = "ERROR: Failed to sign some RPMs in #{args[:rpm_dir]}:\n"
                err_msg += "  #{failures.keys.join("\n  ")}"
                raise(err_msg)
              end
            end
          end
        end

=begin
        desc <<~DESC
          Check that RPMs are signed.

            Checks all RPM files in a directory to see if they are trusted.
              * :rpm_dir - A directory containing RPM files to check. Default #{@build_dir}/SIMP
              * :key_dir - The path to the GPG keys you want to check the packages against. Default #{@src_dir}/assets/gpgkeys/
        DESC
=end
        task :checksig,[:rpm_dir,:key_dir] => [:prep] do |t,args|
          begin

            default_key_dir = File.join(@src_dir, 'assets', 'gpgkeys', 'GPGKEYS')
            args.with_defaults(:rpm_dir => @pkg_dirs[:simp])
            args.with_defaults(:key_dir => default_key_dir)

            rpm_dirs = Dir.glob(args[:rpm_dir])

            fail("Could not find files at #{args[:rpm_dir]}!") if rpm_dirs.empty?

            temp_gpg_dir = Dir.mktmpdir
            at_exit { FileUtils.remove_entry(temp_gpg_dir) if File.exist?(temp_gpg_dir) }

            rpm_cmd = %{rpm --dbpath #{temp_gpg_dir}}

            %x{#{rpm_cmd} --initdb}

            public_keys = Dir.glob(File.join(args[:key_dir], '*'))

            if public_keys.empty?
              key_dirs_tried = [ args[:key_dir] ]

              # try path to GPG keys for SIMP 6.1+
              if (args[:key_dir] != default_key_dir) and File.exist?(default_key_dir)
                key_dirs_tried << default_key_dir
                public_keys = Dir.glob(File.join(default_key_dir, '*'))
              end

              if public_keys.empty?
                # try path to GPG keys for SIMP 6.0
                old_key_dir = File.join(@src_dir, 'assets', 'simp-gpgkeys', 'GPGKEYS')
                if File.exist?(old_key_dir)
                  key_dirs_tried << old_key_dir
                  public_keys = Dir.glob(File.join(old_key_dir, '*'))
                end
              end

              if public_keys.empty?
                $stderr.puts "pkg:checksig: Warning no GPG keys found in #{key_dirs_tried}"
              end
            end

            # be sure to include any development keys packaged with the DVD
            public_keys += Dir.glob(File.join(@dvd_src, 'RPM-GPG-KEY*'))

            # Only import thngs that look like GPG keys...
            public_keys.each do |key|
              next if File.directory?(key) or !File.readable?(key)

              File.read(key).each_line do |line|
                if line =~ /-----BEGIN PGP PUBLIC KEY BLOCK-----/
                  %x{#{rpm_cmd} --import #{key}}
                  break
                end
              end
            end

            bad_rpms = []
            rpm_dirs.each do |rpm_dir|
              Find.find(rpm_dir) do |path|
                if (path =~ /.*\.rpm$/)
                  %x{#{rpm_cmd} --checksig #{path}}.strip
                  result = $?
                  unless result && (result.exitstatus == 0)
                    bad_rpms << path.split(/\s/).first
                  end
                end
              end
            end

            unless bad_rpms.empty?
              bad_rpms.map!{|x| x = "  * #{x}"}
              bad_rpms.unshift("ERROR: Untrusted RPMs found in the repository:")

              fail(bad_rpms.join("\n"))
            else
              puts "Checksig succeeded"
            end
          ensure
            remove_entry_secure temp_gpg_dir if (temp_gpg_dir && File.exist?(temp_gpg_dir))
          end
        end

        desc <<~DESC
          Run repoclosure on RPM files.

            Finds all rpm files in the target dir and all of its subdirectories, then
            reports which packages have unresolved dependencies. This needs to be run
            after rake tasks tar:build and unpack if operating on the basetest SIMP repo.
              * :target_dir  - The directory to assess. Default #{@build_dir}/SIMP.
              * :aux_dir     - Auxillary repo glob to use when assessing. Default #{@build_dir}/Ext_*.
                              Defaults to ''(empty) if :target_dir is not the system default.

            ENV vars:
              - Set `SIMP_PKG_verbose=yes` to report file operations as they happen.
              - Set `SIMP_PKG_repoclose_pe=yes` to enable repoclosure on PE-related RPMs.

        DESC
        task :repoclosure,[:target_dir,:aux_dir] => [:prep] do |t,args|
          default_target = @pkg_dirs[:simp]
          args.with_defaults(:target_dir => File.expand_path(default_target))

          if args[:aux_dir]
            args[:aux_dir] = File.expand_path(args[:aux_dir])
          end

          _repoclose_pe = ENV.fetch('SIMP_PKG_repoclose_pe','no') == 'yes'

          yum_conf_template = <<~YUM_CONF
            [main]
            keepcache=0
            exactarch=1
            obsoletes=1
            gpgcheck=0
            plugins=1
            installonly_limit=5
            <% unless #{_repoclose_pe} -%>
            exclude=*-pe-*
            <% end -%>

            <% repo_files.each do |repo| -%>
            include=file://<%= repo %>
            <% end -%>
          YUM_CONF

          yum_repo_template = <<~YUM_REPO
            [<%= repo_name %>]
            name=<%= repo_name %>
            baseurl=file://<%= repo_path %>
            enabled=1
            gpgcheck=0
            protect=1
          YUM_REPO

          fail("#{args[:target_dir]} does not exist!") unless File.directory?(args[:target_dir])

          Dir.mktmpdir do |temp_pkg_dir|
            Dir.chdir(temp_pkg_dir) do
              mkdir_p('repos/basetest')
              mkdir_p('repos/lookaside')
              mkdir_p('repodata')

              Dir.glob(File.join(args[:target_dir], '**', '*.rpm'))
                .delete_if{|x| x =~ /\.src\.rpm$/}
                .each do |path|
                  sym_path = "repos/basetest/#{File.basename(path)}"
                  ln_sf(path,sym_path, :verbose => @verbose) unless File.exists?(sym_path)
              end

              if args[:aux_dir]
                Dir.glob(File.join(args[:aux_dir], '**', '*.rpm'))
                  .delete_if{|x| x =~ /\.src\.rpm$/}
                  .each do |path|
                    sym_path = "repos/lookaside/#{File.basename(path)}"
                    ln_sf(path,sym_path, :verbose => @verbose) unless File.exists?(sym_path)
                end
              end

              repo_files = []
              Dir.glob('repos/*').each do |repo|
                if File.directory?(repo)
                  Dir.chdir(repo) { sh %{createrepo .} }

                  repo_name = File.basename(repo)
                  repo_path = File.expand_path(repo)
                  conf_file = "#{temp_pkg_dir}/#{repo_name}.conf"

                  File.open(conf_file,'w') do |file|
                    file.write(ERB.new(yum_repo_template,nil,'-').result(binding))
                  end

                  repo_files << conf_file
                end
              end

              File.open('yum.conf', 'w') do |file|
                file.write(ERB.new(yum_conf_template,nil,'-').result(binding))
              end

              dnf_system = which('dnf')
              if dnf_system
                cmd = 'repoclosure -c basetest.conf --disablerepo=* --enablerepo=basetest'
              else
                cmd = 'repoclosure -c repodata -n -t -r basetest -l lookaside -c yum.conf'
              end

              if ENV['SIMP_BUILD_verbose'] == 'yes'
                puts
                puts '-'*80
                puts "#### RUNNING: `#{cmd}`"
                puts "     in path '#{Dir.pwd}'"
                puts '-'*80
              end
              repoclosure_output = %x(#{cmd})

              if (!$?.success? || (repoclosure_output =~ /nresolved/))
                errmsg = ['Error: REPOCLOSURE FAILED:']
                errmsg << [repoclosure_output]
                puts(errmsg.join("\n"))

                if dnf_system
                  if ENV.fetch('SIMP_BUILD_prompt', 'yes') != 'no'
                    puts('- Press any key to continue or ^C to abort -')
                    $stdin.gets
                  end
                else
                  fail('Repoclosure Failed')
                end
              end
            end
          end
        end

        desc <<~DESC
          Print published status of all project RPMs
        DESC
        task :check_published => [:prep] do |t,args|
          begin
            yum_helper = Simp::YUM.new(
              Simp::YUM.generate_yum_conf(File.join(@distro_build_dir, 'yum_data')),
              ENV.fetch('SIMP_YUM_makecache','yes') == 'yes')
          rescue Simp::YUM::Error
          end

          errmsg = Parallel.map(
            # Allow for shell globs
            Array(@build_dirs.values).flatten.sort,
            :in_processes => 1
          ) do |dir|
            _errmsg = nil

            if Dir.exist?(dir)
              begin
                require_rebuild?(dir, yum_helper, {
                  fetch:      false,
                  verbose:    true,
                  check_git:  true,
                  prefix:     ''
                })
              rescue => e
                _errmsg = "Error: require_rebuild?(): Status check failed on '#{dir}' => #{e}"
              end
            else
              _errmsg = "Error: Cound not find specified build directory '#{dir}'"
            end

            _errmsg
          end.compact

          unless errmsg.empty?
            fail(errmsg.join("\n"))
          end
        end

        ##############################################################################
        # Helper methods
        ##############################################################################

        # Generate a random string suitable for a rake task namespace
        #
        # This is used as a workaround for Parallelization
        def generate_namespace
          return (0...24).map{ (65 + rand(26)).chr }.join.downcase
        end

        # Return a SIMP::YUM object configured for the local build dir or nil
        #
        # ENV vars:
        #   - Set `SIMP_PKG_verbose=yes` to report file operations as they happen.
        #   - Set `SIMP_YUM_makecache=no` if you do NOT want to rebuild the
        #     build-specific YUM cache
        def get_yum_helper( makecache = (ENV.fetch('SIMP_YUM_makecache','yes') == 'yes') )
          begin
            build_yum_data = File.join(@distro_build_dir, 'yum_data')
            return Simp::YUM.new(Simp::YUM.generate_yum_conf(build_yum_data), makecache)
          rescue Simp::YUM::Error => e
            $stderr.puts "Simp::YUM::Error: #{e}" if @verbose
          end
        end

        # Check and see if 'dir' requires a rebuild based on published packages
        #
        # If 'fetch' is true => Download the published RPM
        # If 'verbose' is true => Print helpful information to stderr
        # If 'check_git' is true => Print the git tag status if 'verbose' is true
        # 'prefix' is used to prepend verbose messages
        #
        # FIXME
        # - Method is too long
        # - Method needs to be passed in class variables (@xxx) so that it
        #   can be pulled out into a library that is easily unit-testable
        def require_rebuild?(dir, yum_helper, opts={
          unique_namespace:  generate_namespace,
          fetch:             false,
          verbose:           @verbose,
          check_git:         false,
          prefix:            ''
        })
          always_require_rebuild = ENV.select{|x| x =~ /SIMP_BUILD_PKG_require_rebuild/i }
          unless always_require_rebuild.empty?
            return true if always_require_rebuild =~ /\A(yes|always)\Z/i
          end
          result = false
          rpm_metadata = File.exist?(@rpm_dependency_file) ? YAML.load(File.read(@rpm_dependency_file)) : {}
          dir_relpath = Pathname.new(dir).relative_path_from(Pathname.new(Dir.pwd)).to_path
          $stderr.puts "\n  require_rebuild? (#{dir_relpath}):" if @verbose

          Dir.chdir(dir) do
            if File.exist?('metadata.json')
              # Generate RPM metadata files
              # - 'build/rpm_metadata/requires' file containing RPM
              #   dependency/obsoletes information from the
              #   'dependencies.yaml' and the module's
              #   'metadata.json'; always created
              # - 'build/rpm_metadata/release' file containing RPM
              #   release qualifier from the 'dependencies.yaml';
              #   only created if release qualifier if specified in
              #   the 'dependencies.yaml'
              Simp::Rake::Build::RpmDeps::generate_rpm_meta_files(dir, rpm_metadata)

              new_rpm = Simp::Rake::Pkg.new(Dir.pwd, opts[:unique_namespace], @simp_version)
              new_rpm_info = Simp::RPM.new(new_rpm.spec_file)
            else
              spec_file = Dir.glob(File.join('build', '*.spec'))
              fail("No spec file found in #{dir}/build") if spec_file.empty?
              $stderr.puts "    Found spec file: #{File.expand_path(spec_file.first)}" if @verbose
              new_rpm_info = Simp::RPM.new(spec_file.first)
            end

            if @verbose
              $stderr.puts '    Details:'
              $stderr.puts "        Puppetfile name: #{File.basename(dir)}"
              $stderr.puts "        RPM name:        #{new_rpm_info.name}"
              $stderr.puts "        Local directory: #{dir}"
            end

            if opts[:check_git]
              git_origin_url = nil
              ['origin','upstream'].each do |r|
                git_origin_url = %x(git config --get remote.#{r}.url).strip if git_origin_url.to_s.empty?
              end
              $stderr.puts "        Git origin URL:  #{git_origin_url}" if @verbose
              require_tag = false

              #FIXME The check below is insufficient. See logic in compare_latest_tag,
              # which does a git diff between files checked out and latest tag to see
              # if any changes to mission-relevant files have been made and if the
              # version has been bumped, when such changes have been made.
              #
              # We remove any leading 'v' chars since some external projects use them
              latest_tag = %x(git describe --abbrev=0 --tags 2>/dev/null).strip.gsub(/^v/,'')

              # Legacy munge
              # We remove any leading 'simp-', leading 'simp6.0.0-', or trailing
              # '-post1' strings used previously for some projects.  This munge
              # logic can be remove in SIMP 7.
              latest_tag.gsub!(/^simp-|^simp6.0.0-|-post1$/,'')

              begin
                rpm_version = Gem::Version.new(new_rpm_info.version)
                rpm_release = new_rpm_info.release.match(/^(\d+)[.-_]?/) ? new_rpm_info.release.match(/^(\d+)[.-_]?/)[1] : nil
                if @verbose
                  $stderr.puts '        ' + [
                    "RPM version-rel: #{ "#{rpm_version}-#{rpm_release}".ljust(10) }  ",
                    "(semver: #{rpm_version}, relver: #{rpm_release})",
                  ].join
                end
              rescue ArgumentError
                $stderr.puts ">>#{new_rpm_info.basename}: Could not determine RPM version from '#{new_rpm_info.version}'"
              end

              begin
                if latest_tag.empty?
                  require_tag = true
                  $stderr.puts "        Latest Git tag semver:   (none)" if @verbose
                else
                  # Gem::Version interprets an RPM-style release suffix like
                  # `1.2.3-4` as `1.2.3.pre.4`, which is *less* than `1.2.3`.
                  # So we compare SemVer first, then relver numbers if needed
                  latest_tag_version = Gem::Version.new(latest_tag.sub(/-\d+$/,''))
                  latest_tag_release = latest_tag.match(/-(\d+)$/) ? latest_tag.match(/-(\d+)$/)[1].to_i : nil
                  if @verbose
                    $stderr.puts '        ' + [
                      "Latest Git tag:  #{latest_tag.ljust(10)}  ",
                      "(semver: #{latest_tag_version}#{latest_tag_release ? ", relver: #{latest_tag_release}" : nil})",
                    ].join
                  end
                end
              rescue ArgumentError
                $stderr.puts ">>#{git_origin_url}: Invalid git tag version '#{latest_tag}' "
              end

              if rpm_version && latest_tag_version
                # undefined behavior, so far (this current logic skips it):
                #   what to do if rpm_release is set and latest_tag_release is nil?
                if latest_tag_release &&
                   rpm_release &&
                   (rpm_version == latest_tag_version) &&
                   (rpm_release > latest_tag_release)
                  require_tag = true
                elsif rpm_version > latest_tag_version
                  require_tag = true
                end
              end

              if opts[:verbose] && require_tag
                $stderr.puts [
                  "#{opts[:prefix]}Git Release Tag Required: ",
                  "[#{git_origin_url || dir_relpath }] ",
                  "tag: #{latest_tag} => ",
                  "rpm: #{new_rpm_info.version}#{latest_tag_release ? "-#{rpm_release}" : nil} ",
                  "[#{new_rpm_info.basename}]",
                ].join
              end
            end

            # Pull down any newer versions of the target RPM if we've been
            # given a yum_helper
            #
            # Just build from scratch if something goes wrong
            if yum_helper
              # Most RPM spec files generate a single package, but we have
              # a handful that generate multiple (sub-)packages
              new_rpm_info.packages.each do |package|
                begin
                  published_rpm = yum_helper.available_package(package)

                  if published_rpm
                    if new_rpm_info.package_newer?(package, published_rpm)
                      if opts[:verbose]
                        $stderr.puts "#{opts[:prefix]}RPM Publish Required: #{published_rpm} => #{new_rpm_info.rpm_name(package)}"
                      end
                      result = true
                    else
                      $stderr.puts "#{opts[:prefix]}Found Existing Remote RPM: #{published_rpm}" if opts[:verbose]
                      if opts[:fetch]
                        # Download published RPM, unless it's already been downloaded.
                        # TODO Unhandled edge case: Validate that downloaded RPM is valid
                        if File.exist?(File.join('dist', published_rpm))
                          $stderr.puts "#{opts[:prefix]}#{published_rpm} previously downloaded" if opts[:verbose]
                        else
                          # We know the package exists. So in a brute-force fashion,
                          # we're going to retry a couple of times.
                          # (Real fix is for user to update retry and timeout parameters
                          # in their yum config).
                          tries = ENV.fetch('SIMP_YUM_retries','3').to_i
                          begin
                            yum_helper.download("#{package}", :target_dir => 'dist')
                            $stderr.puts "#{opts[:prefix]}Downloaded #{published_rpm}" if opts[:verbose]
                          rescue Simp::YUM::Error
                            tries -= 1
                            if tries > 0
                              retry
                            else
                              $stderr.puts ">>Failed to download existing remote RPM: #{published_rpm}. RPM will be locally rebuilt"
                              result = true
                            end
                          end
                        end
                      end
                    end
                  else
                    if opts[:verbose]
                      $stderr.puts "#{opts[:prefix]}RPM Publish Required (new RPM): #{new_rpm_info.rpm_name(package)}"
                    end
                    result = true
                  end
                rescue Simp::YUM::Error => e
                  $stderr.puts e if opts[:verbose]
                end
              end
            else
              $stderr.puts '>>Issue creating YUM configuration. Packages will be locally generated.' if opts[:verbose]

              result = true
            end
          end

          return result
        end

        def build_pupmod_rpm(dir, yum_helper, dbg_prefix = '  ')
          unique_namespace = generate_namespace
          if require_rebuild?(dir, yum_helper, {
            unique_namespace:  unique_namespace,
            fetch:             @fetch_published_rpm.nil? ? true : @fetch_published_rpm,
            verbose:           @verbose,
            prefix:            dbg_prefix,
          })
            $stderr.puts("#{dbg_prefix}Running 'rake pkg:rpm' on #{File.basename(dir)}") if @verbose
            Rake::Task["#{unique_namespace}:pkg:rpm"].invoke
          else
            # Record metadata for the downloaded RPM
            Simp::RPM::create_rpm_build_metadata(File.expand_path(dir))
          end
          true
        end


        def build_rakefile_rpm(dir, yum_helper, dbg_prefix = '  ')
          if require_rebuild?(dir, yum_helper, {
            fetch:    @fetch_published_rpm.nil? ? true : @fetch_published_rpm,
            verbose:  @verbose,
            prefix:   dbg_prefix
          })
            $stderr.puts("#{dbg_prefix}Running 'rake pkg:rpm' in #{File.basename(dir)}") if @verbose
            rake_flags = Rake.application.options.trace ? '--trace' : ''
            cmd = %{SIMP_BUILD_version=#{@simp_version} rake pkg:rpm #{rake_flags} 2>&1}

            build_success = true
            begin
              %x{#{cmd}}
              build_success = $?.success?

              built_rpm = true
            rescue
              build_success = false
            end

            unless build_success
              if @verbose
                $stderr.puts("First 'rake pkg:rpm' attempt for #{dir} failed, running bundle and trying again.")
              end

              if Bundler.respond_to?(:with_unbundled_env)
                # Bundler 2.1+
                clean_env_method = :with_unbundled_env
                bundle_install_cmd = %{bundle config set with 'development' && bundle install}
              else
                # Old Bundler
                clean_env_method = :with_clean_env
                bundle_install_cmd = %{bundle install --with development}
              end

              ::Bundler.send(clean_env_method) do
                %x{#{bundle_install_cmd}}

                output = %x{#{cmd} 2>&1}

                unless $?.success?
                  raise("Error in #{dir} running #{cmd}\n#{output}")
                end
              end
            end
          else
            # Record metadata for the downloaded RPM
            Simp::RPM::create_rpm_build_metadata(File.expand_path(dir))
            built_rpm = true
          end
        end


        # Takes a list of directories to hop into and perform builds within
        #
        # The task must be passed so that we can output the calling name in the
        # status bar.
        def build(dirs, task, rebuild_for_arch=false, remake_yum_cache = false)
          fail("Could not find RPM dependency file '#{@rpm_dependency_file}'") unless File.exist?(@rpm_dependency_file)
          yum_helper = get_yum_helper( remake_yum_cache )

          Parallel.map(
            # Allow for shell globs
            Array(dirs), {
              in_processes:  @cpu_limit,
              progress:      (ENV.fetch('SIMP_PKG_progress_bar','yes') == 'yes') ? task.name : nil,
            }
          ) do |dir|
            fail("Could not find directory #{dir}") unless Dir.exist?(dir)

            Dir.chdir(dir) do
              built_rpm = false
              $stderr.puts("\nPackaging #{File.basename(dir)}") if @verbose

              if File.exist?('metadata.json')
                # We're building a module, override anything down there
                built_rpm = build_pupmod_rpm(dir, yum_helper)
              elsif File.exist?('Rakefile')
                # We're building one of the extra assets and should honor its Rakefile
                # and RPM spec file.
                built_rpm = build_rakefile_rpm(dir, yum_helper)
              else
                puts "Warning: '#{dir}' could not be built (not a pupmod & no Rakefile!)"
              end

              if built_rpm
                tarballs = Dir.glob('dist/*.tar.gz')
                rpms = Dir.glob('dist/*.rpm').delete_if{|x| x =~ %r(\.src\.rpm$)}

                # Not all items generate tarballs
                tarballs.each do |pkg|
                  if (File.stat(pkg).size == 0)
                    raise("Empty Tarball '#{pkg}' generated for #{dir}")
                  end
                end

                raise("No RPMs generated for #{dir}") if rpms.empty?
              end
              $stderr.puts("Finished  #{File.basename(dir)}") if @verbose
            end
          end
        end

        #desc "Checks the environment for building the DVD tarball
        def check_dvd_env
          ["#{@dvd_src}/isolinux","#{@dvd_src}/ks"].each do |dir|
            File.directory?(dir) or raise "Environment not suitable: Unable to find directory '#{dir}'"
          end
        end

        # Return an Array of all puppet module directories
        def get_module_dirs(method='tracking')
          load_puppetfile(method)
          module_paths.select{|x| File.basename(File.dirname(x)) == 'modules'}.sort
        end
      end
    end
  end

end
