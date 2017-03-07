#!/usr/bin/ruby
require 'open3'
require 'fileutils'
require 'libxml' # rum `gem install libxml-ruby`
require 'aws-sdk-v1' # run `gem install aws-sdk-v1`

class Mp4ToMpegDash

  def initialize(filename)
    @config = {
      keyint: '59',
      framerate: '30',
      profile: 'live',
      chunk: '2000',
    }
    @versions = [ '1280', '1024', '768', '640', '480', '320' ]
    @filename = filename

    @versions.each { |version| FileUtils.rm_r(version) if Dir.exists?(version)}
    @versions.each { |version| FileUtils.mkdir(version) }
    FileUtils.rm_r('audio') if Dir.exists?('audio')
    FileUtils.mkdir('audio')
  end

  def create_multiple_bitrate_versions
    lastVersion = '';
    @versions.each do |version|
      r = "ffmpeg -i #{@filename} -vf scale='#{version}:trunc(ih/2)*2' -x264opts 'keyint=#{@config[:keyint]}:min-keyint=#{@config[:keyint]}:no-scenecut' -strict -2 -r #{@config[:framerate]} #{version}/#{@filename} -y"
      Open3.popen3(r) { |sti, sto, ste, thr|
        if thr.value.success?
          lastVersion = version;
          puts "#{version} transcode successfully!"
        else
          puts "#{version} transcode failed! #{ste.inspect}"
        end
      }
    end

    Open3.popen3("cp #{lastVersion}/#{@filename} audio/#{@filename}") { |sti, sto, ste, thr|
      if thr.value.success?
        puts "copy #{lastVersion} to audio folder successfully!"
      else
        puts "copy #{lastVersion} to audio folder failed!"
      end
    }
  end

  def create_multiple_segments
    @versions.each do |version|
      r = "cd #{version}; MP4Box -dash #{@config[:chunk]} -frag #{@config[:chunk]} -rap -frag-rap -profile #{@config[:profile]} #{@filename}#video; rm #{@filename}; cd .."
      Open3.popen3(r) { |sti, sto, ste, thr|
        if thr.value.success?
          puts "#{version} create video chunk successfully!"
        else
          puts "#{version} create video chunk failed!"
        end
      }
    end
    r = "cd audio; MP4Box -dash #{@config[:chunk]} -frag #{@config[:chunk]} -rap -frag-rap -profile #{@config[:profile]} #{@filename}#audio; rm #{@filename}; cd .."
    Open3.popen3(r) { |sti, sto, ste, thr|
      if thr.value.success?
        puts "create audio chunk successfully!"
      else
        puts "create audio chunk failed!"
      end
    }
  end

  def merge_manifests
    filename_without_ext = File.basename(@filename, '.mp4')
    main_xml = LibXML::XML::Document.new
    main_mpd = LibXML::XML::Node.new('MPD')
    main_period = LibXML::XML::Node.new('Period')
    main_video_AdaptationSet = LibXML::XML::Node.new('AdaptationSet')
    { mimeType: "video/mp4", contentType: "video", subsegmentAlignment: "true", subsegmentStartsWithSAP: "1", par: "16:9", maxFrameRate: "30", lang: "eng"}.each do |k, v|
      LibXML::XML::Attr.new(main_video_AdaptationSet, "#{k}", "#{v}")
    end
    main_video_SegmentTemplate = LibXML::XML::Node.new('SegmentTemplate')
    { media: "$RepresentationID$/#{filename_without_ext}_dash_track1_$Number$.m4s", initialization: "$RepresentationID$/#{filename_without_ext}_dash_track1_init.mp4"}.each do |k, v|
      LibXML::XML::Attr.new(main_video_SegmentTemplate, "#{k}", "#{v}")
    end
    # video section
    @versions.each do |version|
      mpd_file = "#{version}/#{filename_without_ext}_dash.mpd"
      next if !File.exist?(mpd_file)
      child_video_xml = LibXML::XML::Parser.file(mpd_file).parse
      child_MPD = child_video_xml.root
      child_MPD.attributes.each do |attr|
        LibXML::XML::Attr.new(main_mpd, attr.name, attr.value ) unless main_mpd.attributes.map{|a| a.name}.include?(attr.name)# add atributes and value to main xml root node (<MPD> node)
      end
      child_MPD.children.each do |child|
        if child.name == 'Period'
          child.attributes.each do |attr|
            LibXML::XML::Attr.new(main_period, attr.name, attr.value ) unless main_period.attributes.map{|a| a.name}.include?(attr.name)
          end
          child.children.each do |adaptation_set|
            if adaptation_set.name == 'AdaptationSet'
              adaptation_set.children.each do |representation|
                if representation.name == 'Representation'
                  representation.children.each do |segment_template|
                    if segment_template.name == 'SegmentTemplate'
                      segment_template.attributes.each do |sta|
                        if ['timescale', 'startNumber', 'duration'].include?(sta.name)
                          LibXML::XML::Attr.new(main_video_SegmentTemplate, sta.name, sta.value) unless main_video_SegmentTemplate.attributes.map{|a| a.name}.include?(sta.name)
                        end
                      end
                      main_video_AdaptationSet << main_video_SegmentTemplate
                    end
                  end
                  child_representation = LibXML::XML::Node.new('Representation')
                  representation.attributes.each do |attr|
                    if !child_representation.attributes.map{|a| a.name}.include?(attr.name)
                      if attr.name == 'id'
                        LibXML::XML::Attr.new(child_representation, 'id', version)
                      else
                        LibXML::XML::Attr.new(child_representation, attr.name, attr.value)
                      end
                    end
                  end
                  main_video_AdaptationSet << child_representation
                end
              end
            end
          end
        end
      end
    end
    # audio section
    main_audio_AdaptationSet = LibXML::XML::Node.new('AdaptationSet')
    { mimeType: "audio/mp4", contentType: "audio", segmentAlignment:"true", subsegmentAlignment: "true", subsegmentStartsWithSAP: "1", lang: "eng"}.each do |k, v|
      LibXML::XML::Attr.new(main_audio_AdaptationSet, "#{k}", "#{v}")
    end
    main_audo_Accessibility = LibXML::XML::Node.new('Accessibility')
    { schemeIdUri: "urn:tva:metadata:cs:AudioPurposeCS:2007", value: "6" }.each do |k, v|
      LibXML::XML::Attr.new(main_audo_Accessibility, "#{k}", "#{v}")
    end
    main_audio_AdaptationSet << main_audo_Accessibility
    main_audo_Role = LibXML::XML::Node.new('Role')
    { schemeIdUri: "urn:mpeg:dash:role:2011", value: "main" }.each do |k, v|
      LibXML::XML::Attr.new(main_audo_Role, "#{k}", "#{v}")
    end
    main_audio_AdaptationSet << main_audo_Role
    main_audo_segment_template = LibXML::XML::Node.new('SegmentTemplate')
    { media: "$RepresentationID$/#{filename_without_ext}_dash_track2_$Number$.m4s", initialization: "$RepresentationID$/#{filename_without_ext}_dash_track2_init.mp4"}.each do |k, v|
      LibXML::XML::Attr.new(main_audo_segment_template, "#{k}", "#{v}")
    end
    main_audo_representation = LibXML::XML::Node.new('Representation')
    child_audio_xml = LibXML::XML::Parser.file("audio/#{filename_without_ext}_dash.mpd").parse
    child_audio_xml.root.children.each do |period|
      if period.name == 'Period'
        period.children.each do |adaptation_set|
          if adaptation_set.name == 'AdaptationSet'
            adaptation_set.children.each do |representation|
              if representation.name == 'Representation'

                representation.attributes.each do |attr|
                  if !main_audo_representation.attributes.map{|a| a.name}.include?(attr.name)
                    if attr.name == 'id'
                      LibXML::XML::Attr.new(main_audo_representation, 'id', 'audio')
                    else
                      LibXML::XML::Attr.new(main_audo_representation, attr.name, attr.value)
                    end
                  end
                end

                representation.children.each do |audio_params|
                  if audio_params.name == 'AudioChannelConfiguration'
                    child_audio_channel_configuration = LibXML::XML::Node.new('AudioChannelConfiguration')
                    audio_params.attributes.each do |attr|
                      LibXML::XML::Attr.new(child_audio_channel_configuration, attr.name, attr.value)
                    end
                    main_audo_representation << child_audio_channel_configuration
                    main_audio_AdaptationSet << main_audo_representation
                  end
                  if audio_params.name == 'SegmentTemplate'
                    audio_params.attributes.each do |attr|
                      if !main_audo_segment_template.attributes.map{|a| a.name}.include?(attr.name)
                        LibXML::XML::Attr.new(main_audo_segment_template, attr.name, attr.value)
                      end
                    end
                    main_audio_AdaptationSet << main_audo_segment_template
                  end
                end
              end
            end
          end
        end
      end
    end
    main_period << main_video_AdaptationSet
    main_period << main_audio_AdaptationSet
    main_mpd << main_period
    main_xml.root = main_mpd
    puts main_xml.to_s
    main_xml.save("#{filename_without_ext}_dash.mpd", indent: true)
  end

  def upload_files_to_s3
    uuid = SecureRandom.uuid
    s3 = AWS::S3.new(access_key_id: 'your-acess-key-id', secret_access_key: 'your-secret-access-key')
    bucket = s3.buckets['your-s3-bucket']

    vers = @versions << 'audio'
    vers.each do |version|
      Dir["./#{version}/*"].each do |file|
        key = "#{uuid}/#{version}/#{File.basename(file)}"
        object = bucket.objects[key].write(File.open(file, 'rb'))
        object.acl = :public_read
        puts "https://s3.amazonaws.com/#{bucket.name}/#{object.key}"
      end
    end
    main_mpd = "#{File.basename(@filename, '.mp4')}_dash.mpd"
    key = "#{uuid}/#{main_mpd}"
    object = bucket.objects[key].write(File.open("./#{main_mpd}", 'rb'))
    object.acl = :public_read
    puts "https://s3.amazonaws.com/#{bucket.name}/#{object.key} we need save this url to rails db."
  end
end

file = ARGV[0]
raise "File not exists!" if !File.exist?("./#{file}")

mtd = Mp4ToMpegDash.new(file)
mtd.create_multiple_bitrate_versions
mtd.create_multiple_segments
mtd.merge_manifests
mtd.upload_files_to_s3
