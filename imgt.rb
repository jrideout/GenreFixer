# GenreFixer
#
# GenreFixer attempts to correct the genre of your music files. The genre are gathered
# from the Last.FM API (no user account necessary) tags and then written into the
# ‘Grouping’ field of your music file(s) in iTunes. The genre will be selected by
# choosing the highest rated tag that can be linked to a set of common tags.
#

begin require 'rubygems'; rescue LoadError; end
begin require 'htmlentities'; rescue LoadError; end

require 'appscript'
require 'net/http'
require 'rexml/document'
$:.push(File.dirname($0))
require './vendor/Pashua/Pashua'
include Pashua

class NormalizeTags

  @@genres = {}

  def self.soundex(string)
    copy = string.upcase.tr '^A-Z', ''
    return nil if copy.empty?
    first_letter = copy[0, 1]
    copy.tr_s! 'AEHIOUWYBFPVCGJKQSXZDTLMNR', '00000000111122222222334556'
    copy.sub!(/^(.)\1*/, '').gsub!(/0/, '')
    "#{first_letter}#{copy.ljust(3,"0")}"
  end

  def self.find(tag)
    init if @@genres.empty?
    s = soundex(norm(tag))
    g = @@genres[s]
    g.nil? ? '' : g
  end

  def self.norm(tag)
    tag.split(' ').map(&:capitalize).join(' ').gsub('-','').gsub(" N ", " & ").gsub(" And ", " & ")
  end

  def self.init
    File.open("./genre.txt") do |file|
      file.each do |line|
        l = line.gsub(/\n/,'')
        (genre,synonyms) = l.split('=',2)
        synonyms = genre if synonyms.nil?
        # puts "#{genre} => #{synonyms}"
        synonyms.split(',').each do|syn|
          s = soundex(norm(syn))
          old = @@genres[s]
          puts "WARN: conflicting hash (#{s}) #{old} is being overwritten by #{syn} as #{genre}" unless old.nil?
          @@genres[s] = genre
          # puts "set #{syn} to #{s}"
        end
      end
    end
  end
end

class LastFM

  @@maxTags = 20
  @@minScrobs = 5
  @@apiKey='3ad59bf631147d81c5fe2c93854f65a0'

  def self.maxTags=(mt)
    @@maxTags = mt
  end
  def self.minScrobs=(ms)
    @@minScrobs = ms
  end

  def self.getTags(artistName)
    puts %{  LastFM Query for "#{artistName}"}
    begin
      res = Net::HTTP.get(URI("http://ws.audioscrobbler.com/2.0/" <<
          "?method=artist.getTopTags&artist=#{URI.escape(artistName)}" <<
          "&autocorrect=1&api_key=#{@@apiKey}"))
      doc = REXML::Document.new(res)
    rescue Exception => e
      puts "LastFM API Error: #{e}"
    end
    parse(doc) if doc
  end

  def self.parse(doc)
    # assume that the tags are returned in count sorted order
    tags = REXML::XPath.match(doc, "//toptags/tag[count > #{@@minScrobs} and position()<=#{@@maxTags}]/name")
    artist = REXML::XPath.match(doc, "//toptags/@artist")
    artist = HTMLEntities.new.decode(artist) if defined?(HTMLEntities)
    puts %{  Found: "#{artist}" with #{tags.length} tags ...}
    tags.map { |t| t.text }
  end
end

class Artist
  attr_reader :name, :genre, :cached
  @@cache = {}

  def self.findArtist(*names)
    allNames = names
    allNames.concat names.collect { |n| n.gsub(" & ", " and ") }
    allNames.concat names.collect { |n| n.gsub(/[;\/,]| ft | feat\.? | featuring /i, " & ") }
    allNames.concat names.collect { |n| n.gsub(/ and | with /i, " & ") }
    allNames.concat names.collect { |n| n.gsub(/ vs\.? /i, " & ") }
    allNames.uniq!
    last = Artist.new
    allNames.each do |name|
      a = Artist.new(name)
      a.addTags(last.rawTags)
      return a unless a.genre == ""
      last = a
    end
    last
  end

  def rawTags
    @tags.uniq!
    @tags
  end

  def addTags(tags)
    tags.each do |t|
      @tags << t.strip
    end
  end

  def tags
    @tags.uniq!
    @tags.join(' ')
  end

  def initialize(name='')
    @name = name
    @genre, @backup = '', ''
    @cached = false
    @tags = []

    return if name==''

    if @@cache.include?(@name)
      @genre, @tags = @@cache[@name]
      @cached = true
      puts %{  "#{@name}" found in local database, skipping last.fm query...}
    elsif @name =~ /various/i
      puts %{  "#{@name}" ambigious, skipping last.fm query...}
    else
      addTags(LastFM.getTags(@name))
      findGenre
      @@cache[@name] = [@genre, @tags]
    end
  end

  def findGenre()
    @tags.each do |tag|
      break if @genre != ""
      g = tagToGenre(tag)
      print "  Tag: #{tag}"
      if g != ''
        @genre = g
        print " (matches genre: #{g})"
      end
      puts
    end
    @genre = @backup if @genre == ""
  end

  def tagToGenre(tag)
    if tag =~ /^[1-6]\d[sS]/
      @backup = 'Oldies'
      puts %{  Backup: #{@backup} for #{tag}"}
      return ''
    end
    t = NormalizeTags.find(tag)
    return '' if tag =~ /rap|spotify|danish|rumba/i #known soundex clashes
    return 'Reggae' if t =~ /reggae/i;
    t
  end
end

class Tagger

  def initialize(setGenre=false)
    @tagged, @skipped, @indentical = 0, 0, 0
    @setGenre = setGenre
  end

  def start
    itunes = Appscript.app('iTunes')
    itunes.selection.get.each do |track|
      puts %{======== Looking for "#{track.artist.get}" or "#{track.album_artist.get}" ========}
      artist = Artist.findArtist(track.artist.get,track.album_artist.get)
      if artist.tags == ""
        puts %{  No tags found}
        @skipped += 1
      else
        puts %{  Tagging as "#{artist.tags}"}
        track.grouping.set(artist.tags)
        if @setGenre && artist.genre != ""
          puts %{  Setting genre to "#{artist.genre}"}
          track.genre.set(artist.genre)
        end
        if artist.cached
          @indentical += 1
        else
          @tagged += 1
        end
      end
    end
    puts "\nDone!\n\nTags Found:\t#{@tagged}\nSkipped:\t\t#{@skipped}\nIdentical:\t#{@indentical}"
  end

end

pashuaConfig = <<EOS
# Set transparency: 0 is transparent, 1 is opaque
*.transparency=0.95
*.x=20
*.y=40

# Set window title
*.title = GenreFixer

# Introductory text
txt.type = text
txt.default = GenreFixer adds descriptive metadata to your music. These descriptive tags are gathered from the Last.FM API (no user account necessary) and then written into the 'Grouping' field of your music file(s).
txt.width = 360

txt4.type = text
txt4.default = To write the tags to your files, select any number of songs in iTunes and hit 'Get Tags!' at the bottom of this window.
txt4.width = 360

# Introductory text
txt3.type = text
txt3.default = NOTE: The 'Grouping' field is typically unused and therefore empty, but be sure nothing important is in this field for the selected songs before running. If anything is in the field it will be overwritten.
txt3.width = 360

# Set Genre
genre.type = checkbox
genre.default = 1
genre.label = Set the Genre field?

# Add a text field
minscrobs.type = textfield
minscrobs.label = Minimum popularity of tag (Integer)
minscrobs.default = 5
minscrobs.width = 60

# Add a text field
maxtags.type = textfield
maxtags.label = Maximum tags to save (Integer)
maxtags.default = 20
maxtags.width = 60

# Add a cancel button with default label
cb.type = cancelbutton

db.type = defaultbutton
db.label = Get Tags!

EOS

$KCODE = "u"
puts "Starting GenreFixer ...\n\n"
res = pashua_run(pashuaConfig, '', 'vendor/Pashua/')

if res['cb'] == "1"
  puts "Looks like the dialog was cancelled"
elsif res.empty?
  puts "Looks like a Pashua error"
else
  LastFM.maxTags = Integer(res['maxtags'])
  LastFM.minScrobs = Integer(res['minscrobs'])
  doSetGenre = Integer(res['genre']) == 1
  Tagger.new(doSetGenre).start
end

