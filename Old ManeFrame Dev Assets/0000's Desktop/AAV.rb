#!/usr/bin/env ruby
#
# hotline is a curses-based audio visualization tool. It takes an audio
# file and a video file and creates a composite, colour
# ASCII visualization.
# 
# Currently, hotline requires sox (if audio is not in raw format),
# ffmpeg (if video is not already in ASCII), and aview (ditto). Right
# now only a custom version of aview works. Homebrew formula:
# https://gist.github.com/mistydemeo/043274d4440b7017f593/raw/4e313e2e8f63da934e1c44c22009e3a415c3d9a7/aview.rb
# Patch:
# https://gist.github.com/mistydemeo/982ef8adf468c1e57457/raw/76a8ef7fe1624286152c81ddaa0eb7256bcc3429/aview.diff
# 
# Usage:
# 
# hotline source_audio source_video [--cache-video]
# 
# When --cache-video is specified, hotline will output a marshalled
# copy of the ASCII video to standard out and won't play back the
# visualization. You can use this to prerender video and avoid the
# excruciatingly long startup time when ffmpeg is converting video.

require 'curses'
require 'fileutils'
require 'tmpdir'
require 'narray' # gem narray
require 'numru/fftw3' # gem ruby-fftw3
require 'coreaudio' # gem coreaudio

# frames get dropped here
$video_dir = Dir.mktmpdir
at_exit { FileUtils.rm_r $video_dir }

# Chosen by fair dice roll
$sample_size = 5880

include Curses

init_screen()
start_color()

# Sadly NArray doesn't include Enumerable, even though it
# defines its own #each
class NArray; include Enumerable; end

def color mag, average
  size = mag / average

  if size >= 1
    [COLOR_RED, true]
  elsif size >= 0.9
    COLOR_RED
  elsif size >= 0.8
    [COLOR_YELLOW, true]
  elsif size >= 0.7
    COLOR_YELLOW
  elsif size >= 0.6
    [COLOR_MAGENTA, true]
  elsif size >= 0.5
    COLOR_MAGENTA
  elsif size >= 0.4
    [COLOR_BLUE, true]
  elsif size >= 0.3
    COLOR_BLUE
  elsif size >= 0.2
    [COLOR_CYAN, true]
  elsif size >= 0.1
    COLOR_CYAN
  else
    COLOR_GREEN
  end
end

def fetch_audio(from)
  raise Errno::EINVAL.new("no audio specified") unless from
  raise Errno::ENOENT.new(from) unless File.exist?(from)

  if File.extname(from) == '.raw'
    File.read(from)
  else
    audio = `sox "#{from}" -t raw - 2>/dev/null`.force_encoding("ascii-8bit")
    raise Errno::EINVAL.new("sox failed reading audio input") unless $?.success?

    audio
  end
end

# Can read frame data already serialized to disk, because ffmpeg's
# writing PPM to disk is really really slow
def fetch_video(from, frames)
  raise Errno::EINVAL.new("no video specified") unless from
  raise Errno::ENOENT.new(from) unless File.exist?(from)

  if File.extname(from) == '.txt'
    Marshal.load(File.read(from).force_encoding('ascii-8bit'))
  else
    system "ffmpeg", "-i", from, "-f", "image2", "-vframes", frames.to_s, "#{$video_dir}/%05d.ppm", 1 => IO::NULL, 2 => IO::NULL

    (0..frames).map do |n|
      image_path = File.join($video_dir,"%05d.ppm" % (n+1))
      `aview -driver stdout -height 26 "#{image_path}"`.split("\f")[1][1..-1] if File.exist? image_path
    end.compact
  end
end

audio = fetch_audio(ARGV[0])
video = fetch_video(ARGV[1], audio.bytesize/$sample_size)

if ARGV.include? '--cache-video'
  $stdout.puts Marshal.dump(video)
  exit
end

dev = CoreAudio.default_output_device
buf = dev.output_buffer($sample_size)
buf.start

(0..audio.bytesize/$sample_size).each do |n|
  pos = n * $sample_size
  sample = audio[pos..pos+$sample_size-1]

  na = NArray.to_narray(sample, NArray::SINT, 2, sample.bytesize/4)
  na_f = na.to_f

  na_complex = NumRu::FFTW3.fft(na_f,-1)
  average_mag = na_complex[0..1].map {|n| n.magnitude}.inject(0,:+)/2
  sample_mag = na_complex.map {|n| n.magnitude}.inject(0,:+)/na_complex.size

  intensities = []
  (0..12).each do |n|
    pos = $sample_size/26 * n
    magnitude = na_complex[pos+2..pos+($sample_size/26)+1].map {|n| n.magnitude}.inject(0,:+)/($sample_size/26)
    # 0 is reserved, so we have to start from 1
    color, intense = color(magnitude, sample_mag)
    intensities << intense
    init_pair(n+1,COLOR_BLACK,color)
  end

  buf << na

  image = video[n]
  break unless image

  setpos(0,0)
  image.lines.each_slice(2).with_index do |lines, index|
    lines.each_with_index do |l,i|
      setpos(index*2+i,0)
      intensity = intensities[index] ? A_NORMAL : A_BOLD
      attron(color_pair(index+1|intensity)) { addstr(l.chomp) }
    end
  end

  refresh()
end

buf.stop