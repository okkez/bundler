# frozen_string_literal: true
require "spec_helper"

describe "bundle install from an existing gemspec" do
  before(:each) do
    build_gem "bar", :to_system => true
    build_gem "bar-dev", :to_system => true
  end

  it "should install runtime and development dependencies" do
    build_lib("foo", :path => tmp.join("foo")) do |s|
      s.write("Gemfile", "source :rubygems\ngemspec")
      s.add_dependency "bar", "=1.0.0"
      s.add_development_dependency "bar-dev", "=1.0.0"
    end
    install_gemfile <<-G
      source "file://#{gem_repo2}"
      gemspec :path => '#{tmp.join("foo")}'
    G

    expect(the_bundle).to include_gems "bar 1.0.0"
    expect(the_bundle).to include_gems "bar-dev 1.0.0", :groups => :development
  end

  it "that is hidden should install runtime and development dependencies" do
    build_lib("foo", :path => tmp.join("foo")) do |s|
      s.write("Gemfile", "source :rubygems\ngemspec")
      s.add_dependency "bar", "=1.0.0"
      s.add_development_dependency "bar-dev", "=1.0.0"
    end
    FileUtils.mv tmp.join("foo", "foo.gemspec"), tmp.join("foo", ".gemspec")

    install_gemfile <<-G
      source "file://#{gem_repo2}"
      gemspec :path => '#{tmp.join("foo")}'
    G

    expect(the_bundle).to include_gems "bar 1.0.0"
    expect(the_bundle).to include_gems "bar-dev 1.0.0", :groups => :development
  end

  it "should handle a list of requirements" do
    build_gem "baz", "1.0", :to_system => true
    build_gem "baz", "1.1", :to_system => true

    build_lib("foo", :path => tmp.join("foo")) do |s|
      s.write("Gemfile", "source :rubygems\ngemspec")
      s.add_dependency "baz", ">= 1.0", "< 1.1"
    end
    install_gemfile <<-G
      source "file://#{gem_repo2}"
      gemspec :path => '#{tmp.join("foo")}'
    G

    expect(the_bundle).to include_gems "baz 1.0"
  end

  it "should raise if there are no gemspecs available" do
    build_lib("foo", :path => tmp.join("foo"), :gemspec => false)

    error = install_gemfile(<<-G)
      source "file://#{gem_repo2}"
      gemspec :path => '#{tmp.join("foo")}'
    G
    expect(error).to match(/There are no gemspecs at #{tmp.join('foo')}/)
  end

  it "should raise if there are too many gemspecs available" do
    build_lib("foo", :path => tmp.join("foo")) do |s|
      s.write("foo2.gemspec", build_spec("foo", "4.0").first.to_ruby)
    end

    error = install_gemfile(<<-G)
      source "file://#{gem_repo2}"
      gemspec :path => '#{tmp.join("foo")}'
    G
    expect(error).to match(/There are multiple gemspecs at #{tmp.join('foo')}/)
  end

  it "should pick a specific gemspec" do
    build_lib("foo", :path => tmp.join("foo")) do |s|
      s.write("foo2.gemspec", "")
      s.add_dependency "bar", "=1.0.0"
      s.add_development_dependency "bar-dev", "=1.0.0"
    end

    install_gemfile(<<-G)
      source "file://#{gem_repo2}"
      gemspec :path => '#{tmp.join("foo")}', :name => 'foo'
    G

    expect(the_bundle).to include_gems "bar 1.0.0"
    expect(the_bundle).to include_gems "bar-dev 1.0.0", :groups => :development
  end

  it "should use a specific group for development dependencies" do
    build_lib("foo", :path => tmp.join("foo")) do |s|
      s.write("foo2.gemspec", "")
      s.add_dependency "bar", "=1.0.0"
      s.add_development_dependency "bar-dev", "=1.0.0"
    end

    install_gemfile(<<-G)
      source "file://#{gem_repo2}"
      gemspec :path => '#{tmp.join("foo")}', :name => 'foo', :development_group => :dev
    G

    expect(the_bundle).to include_gems "bar 1.0.0"
    expect(the_bundle).not_to include_gems "bar-dev 1.0.0", :groups => :development
    expect(the_bundle).to include_gems "bar-dev 1.0.0", :groups => :dev
  end

  it "should match a lockfile even if the gemspec defines development dependencies" do
    build_lib("foo", :path => tmp.join("foo")) do |s|
      s.write("Gemfile", "source 'file://#{gem_repo1}'\ngemspec")
      s.add_dependency "actionpack", "=2.3.2"
      s.add_development_dependency "rake", "=10.0.2"
    end

    Dir.chdir(tmp.join("foo")) do
      bundle "install"
      # This should really be able to rely on $stderr, but, it's not written
      # right, so we can't. In fact, this is a bug negation test, and so it'll
      # ghost pass in future, and will only catch a regression if the message
      # doesn't change. Exit codes should be used correctly (they can be more
      # than just 0 and 1).
      output = bundle("install --deployment")
      expect(output).not_to match(/You have added to the Gemfile/)
      expect(output).not_to match(/You have deleted from the Gemfile/)
      expect(output).not_to match(/install in deployment mode after changing/)
    end
  end

  it "should evaluate the gemspec in its directory" do
    build_lib("foo", :path => tmp.join("foo"))
    File.open(tmp.join("foo/foo.gemspec"), "w") do |s|
      s.write "raise 'ahh' unless Dir.pwd == '#{tmp.join("foo")}'"
    end

    install_gemfile <<-G
      gemspec :path => '#{tmp.join("foo")}'
    G
    expect(@err).not_to match(/ahh/)
  end

  it "allows conflicts" do
    build_lib("foo", :path => tmp.join("foo")) do |s|
      s.version = "1.0.0"
      s.add_dependency "bar", "= 1.0.0"
    end
    build_gem "deps", :to_system => true do |s|
      s.add_dependency "foo", "= 0.0.1"
    end
    build_gem "foo", "0.0.1", :to_system => true

    install_gemfile <<-G
      source "file://#{gem_repo2}"
      gem "deps"
      gemspec :path => '#{tmp.join("foo")}', :name => 'foo'
    G

    expect(the_bundle).to include_gems "foo 1.0.0"
  end

  context "when child gemspecs conflict with a released gemspec" do
    before do
      # build the "parent" gem that depends on another gem in the same repo
      build_lib "source_conflict", :path => bundled_app do |s|
        s.add_dependency "rack_middleware"
      end

      # build the "child" gem that is the same version as a released gem, but
      # has completely different and conflicting dependency requirements
      build_lib "rack_middleware", "1.0", :path => bundled_app("rack_middleware") do |s|
        s.add_dependency "rack", "1.0" # anything other than 0.9.1
      end
    end

    it "should install the child gemspec's deps" do
      install_gemfile <<-G
        source "file://#{gem_repo1}"
        gemspec
      G

      expect(the_bundle).to include_gems "rack 1.0"
    end
  end

  context "with a lockfile and some missing dependencies" do
    let(:source_uri) { "http://localgemserver.test" }

    context "previously bundled for Ruby" do
      let(:platform) { "ruby" }
      let(:explicit_platform) { false }

      before do
        build_lib("foo", :path => tmp.join("foo")) do |s|
          s.add_dependency "rack", "=1.0.0"
        end

        if explicit_platform
          create_file(
            tmp.join("foo", "foo-#{platform}.gemspec"),
            build_spec("foo", "1.0", platform) do
              dep "rack", "=1.0.0"
              @spec.authors = "authors"
              @spec.summary = "summary"
            end.first.to_ruby
          )
        end

        gemfile <<-G
          source "#{source_uri}"
          gemspec :path => "../foo"
        G

        lockfile <<-L
          PATH
            remote: ../foo
            specs:
              foo (1.0)
                rack (= 1.0.0)

          GEM
            remote: #{source_uri}
            specs:
              rack (1.0.0)

          PLATFORMS
            #{generic_local_platform}

          DEPENDENCIES
            foo!

          BUNDLED WITH
             #{Bundler::VERSION}
        L
      end

      context "using JRuby with explicit platform" do
        let(:platform) { "java" }
        let(:explicit_platform) { true }

        it "should install" do
          simulate_ruby_engine "jruby" do
            simulate_platform "java" do
              results = bundle "install", :artifice => "endpoint"
              expect(results).to include("Installing rack 1.0.0")
              expect(the_bundle).to include_gems "rack 1.0.0"
            end
          end
        end
      end

      context "using JRuby" do
        let(:platform) { "java" }

        it "should install" do
          simulate_ruby_engine "jruby" do
            simulate_platform "java" do
              results = bundle "install", :artifice => "endpoint"
              expect(results).to include("Installing rack 1.0.0")
              expect(the_bundle).to include_gems "rack 1.0.0"
            end
          end
        end
      end

      context "using Windows" do
        it "should install" do
          simulate_windows do
            results = bundle "install", :artifice => "endpoint"
            expect(results).to include("Installing rack 1.0.0")
            expect(the_bundle).to include_gems "rack 1.0.0"
          end
        end
      end
    end

    context "bundled for ruby and jruby" do
      let(:platform_specific_type) { :runtime }
      let(:dependency) { "platform_specific" }
      before do
        build_repo2 do
          build_gem "indirect_platform_specific" do |s|
            s.add_runtime_dependency "platform_specific"
          end
        end

        build_lib "foo", :path => "." do |s|
          if platform_specific_type == :runtime
            s.add_runtime_dependency dependency
          elsif platform_specific_type == :development
            s.add_development_dependency dependency
          else
            raise "wrong dependency type #{platform_specific_type}, can only be :development or :runtime"
          end
        end

        %w(ruby jruby).each do |platform|
          simulate_platform(platform) do
            install_gemfile <<-G
              source "file://#{gem_repo2}"
              gemspec
            G
          end
        end
      end

      context "on ruby" do
        before do
          simulate_platform("ruby")
          bundle :install
        end

        context "as a runtime dependency" do
          it "keeps java dependencies in the lockfile" do
            expect(the_bundle).to include_gems "foo 1.0", "platform_specific 1.0 RUBY"
            expect(lockfile).to eq strip_whitespace(<<-L)
              PATH
                remote: .
                specs:
                  foo (1.0)
                    platform_specific

              GEM
                remote: file:#{gem_repo2}/
                specs:
                  platform_specific (1.0)
                  platform_specific (1.0-java)

              PLATFORMS
                java
                ruby

              DEPENDENCIES
                foo!

              BUNDLED WITH
                 #{Bundler::VERSION}
            L
          end
        end

        context "as a development dependency" do
          let(:platform_specific_type) { :development }

          it "keeps java dependencies in the lockfile" do
            expect(the_bundle).to include_gems "foo 1.0", "platform_specific 1.0 RUBY"
            expect(lockfile).to eq strip_whitespace(<<-L)
              PATH
                remote: .
                specs:
                  foo (1.0)

              GEM
                remote: file:#{gem_repo2}/
                specs:
                  platform_specific (1.0)
                  platform_specific (1.0-java)

              PLATFORMS
                java
                ruby

              DEPENDENCIES
                foo!
                platform_specific

              BUNDLED WITH
                 #{Bundler::VERSION}
            L
          end
        end

        context "with an indirect platform-specific development dependency" do
          let(:platform_specific_type) { :development }
          let(:dependency) { "indirect_platform_specific" }

          it "keeps java dependencies in the lockfile" do
            expect(the_bundle).to include_gems "foo 1.0", "indirect_platform_specific 1.0", "platform_specific 1.0 RUBY"
            expect(lockfile).to eq strip_whitespace(<<-L)
              PATH
                remote: .
                specs:
                  foo (1.0)

              GEM
                remote: file:#{gem_repo2}/
                specs:
                  indirect_platform_specific (1.0)
                    platform_specific
                  platform_specific (1.0)
                  platform_specific (1.0-java)

              PLATFORMS
                java
                ruby

              DEPENDENCIES
                foo!
                indirect_platform_specific

              BUNDLED WITH
                 #{Bundler::VERSION}
            L
          end
        end
      end
    end
  end
end
