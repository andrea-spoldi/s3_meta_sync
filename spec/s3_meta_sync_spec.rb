require "spec_helper"

describe S3MetaSync do
  let(:config) { YAML.load_file(File.expand_path("../credentials.yml", __FILE__)) }
  let(:s3) { AWS::S3.new(:access_key_id => config[:key], :secret_access_key => config[:secret]).buckets[config[:bucket]] }
  let(:foo_md5) { "---\nxxx: 0976fb571ada412514fe67273780c510\n" }
  let(:syncer) { S3MetaSync::Syncer.new(config) }

  def cleanup_s3
    s3.objects.each { |o| o.delete }
  end

  def upload_simple_structure
    `mkdir foo && echo yyy > foo/xxx`
    syncer.sync("foo", "#{config[:bucket]}:bar")
  end

  def download(file)
    open("https://s3-us-west-2.amazonaws.com/#{config[:bucket]}/#{file}").read
  rescue
    nil
  end

  def with_utf8_encoding
    old = Encoding.default_external, Encoding.default_internal
    Encoding.default_external = Encoding.default_internal = Encoding::UTF_8
    yield
  ensure
    Encoding.default_external, Encoding.default_internal = old
  end

  around do |test|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir, &test)
    end
  end

  it "has a VERSION" do
    S3MetaSync::VERSION.should =~ /^[\.\da-z]+$/
  end

  describe "#sync" do
    before do
      $stderr.stub(:puts)
      upload_simple_structure
    end
    after { cleanup_s3 }

    context "sync local to remote" do
      it "uploads files" do
        download("bar/xxx").should == "yyy\n"
        download("bar/.s3-meta-sync").should == foo_md5
      end

      it "removes obsolete files" do
        `rm foo/xxx && echo yyy > foo/zzz`
        syncer.sync("foo", "#{config[:bucket]}:bar")
        download("bar/xxx").should == nil
        download("bar/zzz").should == "yyy\n"
      end

      it "does not upload/delete when nothing needs to be done" do
        syncer.should_receive(:upload_file).with("foo", ".s3-meta-sync", "bar")
        syncer.should_not_receive(:delete_remote_file)
        syncer.sync("foo", "#{config[:bucket]}:bar")
      end
    end

    context "sync remote to local" do
      let(:no_cred_syncer) { S3MetaSync::Syncer.new(:region => config[:region]) }

      it "fails when trying to download an empty folder (which would remove everything)" do
        expect {
          no_cred_syncer.sync("#{config[:bucket]}:baz", "foo")
        }.to raise_error(S3MetaSync::RemoteWithoutMeta)
      end

      it "downloads into an empty folder" do
        no_cred_syncer.sync("#{config[:bucket]}:bar", "foo2")
        File.read("foo2/xxx").should == "yyy\n"
        File.read("foo2/.s3-meta-sync").should == foo_md5
      end

      it "downloads nothing when everything is up to date" do
        no_cred_syncer.should_receive(:download_file).with("bar", ".s3-meta-sync", "foo")
        no_cred_syncer.should_not_receive(:delete_local_file)
        no_cred_syncer.sync("#{config[:bucket]}:bar", "foo")
      end

      it "deletes obsolete local files" do
        `echo yyy > foo/zzz`
        no_cred_syncer.sync("#{config[:bucket]}:bar", "foo")
        File.exist?("foo/zzz").should == false
      end

      it "removes empty folders" do
        `mkdir foo/baz`
        no_cred_syncer.sync("#{config[:bucket]}:bar", "foo")
        File.exist?("foo/baz").should == false
      end

      it "overwrites locally changed files" do
        `echo fff > foo/xxx`
        no_cred_syncer.sync("#{config[:bucket]}:bar", "foo")
        File.read("foo/xxx").should == "yyy\n"
      end
    end
  end

  it "can upload and download a utf-8 file" do
    with_utf8_encoding do
      syncer.instance_variable_set(:@bucket, config[:bucket])
      expected = "…"
      `mkdir foo`
      File.write("foo/utf8", expected)
      syncer.send(:upload_file, "foo", "utf8", "bar")
      syncer.send(:download_file, "bar", "utf8", "baz")
      read = File.read("baz/utf8")
      read.should == expected
      read.encoding.should == Encoding::UTF_8
      read[/…/].should == "…"
    end
  end

  describe ".parse_options" do
    after do
      ENV.delete "AWS_ACCESS_KEY_ID"
      ENV.delete "AWS_SECRET_ACCESS_KEY"
    end

    def call(*args)
      S3MetaSync.send(:parse_options, *args)
    end

    it "fails with empty" do
      expect { call([]) }.to raise_error
    end

    it "fails with 2 remotes" do
      expect { call(["x:z", "z:y", "--key", "k", "--secret", "s"]) }.to raise_error
    end

    it "fails with 2 locals" do
      expect { call(["x", "z"]) }.to raise_error
    end

    it "parses source + destination" do
      call(["x:z", "y"]).should == ["x:z", "y", {:key => nil, :secret => nil}]
    end

    it "parses key + secret" do
      call(["x", "y:z", "--key", "k", "--secret", "s"]).should == ["x", "y:z", {:key => "k", :secret => "s"}]
    end

    it "fails with missing key" do
      expect { call(["x", "y:z", "--secret", "s"]) }.to raise_error
    end

    it "fails with missing secret" do
      expect { call(["x", "y:z", "--key", "k"]) }.to raise_error
    end

    it "fails with missing key and secret" do
      expect { call(["x", "y:z"]) }.to raise_error
    end

    it "takes key and secret from the environment" do
      ENV["AWS_ACCESS_KEY_ID"] = "k"
      ENV["AWS_SECRET_ACCESS_KEY"] = "s"
      call(["x", "y:z"]).should == ["x", "y:z", {:key => "k", :secret => "s"}]
    end

    it "take verbose mode" do
      call(["x:z", "y", "-V"]).should == ["x:z", "y", {:key => nil, :secret => nil, :verbose => true}]
      call(["x:z", "y", "--verbose"]).should == ["x:z", "y", {:key => nil, :secret => nil, :verbose => true}]
    end

    it "parses --ssl-none" do
      call(["x:z", "y", "--ssl-none"]).should == ["x:z", "y", {:key => nil, :secret => nil, :ssl_none => true}]
    end
  end

  describe ".download_content" do
    before do
      $stderr.stub(:puts)
      upload_simple_structure
    end
    after { cleanup_s3 }

    it "downloads" do
      syncer.send(:download_content, "bar/xxx").should == "yyy\n"
    end

    it "retries once on ssl error" do
      syncer.should_receive(:open).and_raise OpenSSL::SSL::SSLError.new
      syncer.should_receive(:open).and_return stub(:read => "fff")
      syncer.send(:download_content, "bar/xxx").should == "fff"
    end

    it "does not retry multiple times on ssl error" do
      syncer.should_receive(:open).exactly(2).and_raise OpenSSL::SSL::SSLError.new
      expect { syncer.send(:download_content, "bar/xxx") }.to raise_error(OpenSSL::SSL::SSLError)
    end
  end

  describe "CLI" do
    let(:params) { "--key #{config[:key]} --secret #{config[:secret]} --region #{config[:region]}" }
    def sync(command, options={})
      sh("#{Bundler.root}/bin/s3-meta-sync #{command}", options)
    end

    def sh(command, options={})
      result = `#{command} #{"2>&1" unless options[:keep_output]}`
      raise "#{options[:fail] ? "SUCCESS" : "FAIL"} #{command}\n#{result}" if $?.success? == !!options[:fail]
      result
    end

    it "shows --version" do
      sync("--version").should include(S3MetaSync::VERSION)
    end

    it "shows --help" do
      sync("--help").should include("Sync folders with s3")
    end

    context "upload" do
      around do |test|
        begin
          `mkdir foo && echo yyy > foo/xxx`
          test.call
        ensure
          cleanup_s3
        end
      end

      it "works" do
        sync("foo #{config[:bucket]}:bar #{params}").should == "Uploading: 1 Deleting: 0\n"
        download("bar/xxx").should == "yyy\n"
      end

      it "is verbose" do
        sync("foo #{config[:bucket]}:bar #{params} --verbose").strip.should == <<-TXT.gsub(/^ {10}/, "").strip
          Downloading bar/.s3-meta-sync
          Remote has no .s3-meta-sync, uploading everything
          Uploading: 1 Deleting: 0
          Uploading xxx
          Uploading .s3-meta-sync
        TXT
      end
    end
  end
end
