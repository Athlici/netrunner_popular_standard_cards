require "net/http"
require "json"
require "fileutils"
require "date"
require 'cgi'

IMG_URL = "https://static.nrdbassets.com/v1/large/{code}.jpg"
NRDB_URL = "https://netrunnerdb.com/en/card/{code}"

STANDARD = ["elev","sg","rwr","tai","ph","ms","msbp","ur","urbp","df"]
STARTUP  = ["elev","sg","rwr","tai"]
API_URL = "https://netrunnerdb.com/api/2.0/public/"
WAIT_TIME = 5
CACHE = {}

def get(url)
  resp = Net::HTTP.get_response(URI.parse(url))
  if resp.is_a?(Net::HTTPSuccess)
    resp.body
  else
    puts "Get failed: #{url} HTTP #{resp.code}"
    nil
  end
end

def load_or_request(url, filename)
  if CACHE.key? filename
    CACHE[filename]
  end
  if File.file? filename
    file = File.open filename
    data = JSON.load file
    CACHE[filename] = data
    data
  else
    sleep(WAIT_TIME)
    data = get(url)
    if data.nil?
      return nil
    end
    File.open(filename, "w") do |f|
      f.write(data)
    end
    JSON.parse(data)
  end
end

def fetch(base, path, tail)
  filename = "data/" + path + tail
  url = base + path + tail
  FileUtils.mkdir_p("data/" + path)
  load_or_request(url, filename)
end

def get_decks_by_date(date)
  path = "decklists/by_date/"
  tail = date.to_s
  data = fetch(API_URL, path, tail)
  data["data"]
end

def get_deck(deck_id)
  path = "decklist/"
  tail = deck_id.to_s
  data = fetch(API_URL, path, tail)
  data["data"][0]
end

def get_card(card_code)
  path = "card/"
  tail = card_code.to_s
  data = fetch(API_URL, path, tail)
  data["data"][0]
end

def get_all_cycles()
  filename = "data/cycles"
  url = API_URL + "cycles"
  data = load_or_request(url, filename)
  return data["data"]
end

def get_all_packs()
  filename = "data/packs"
  url = API_URL + "packs"
  data = load_or_request(url, filename)
  return data["data"]
end

def get_active_packs()
  cycles = get_all_cycles()
  active_cycles = cycles.select { |cycle| !cycle["rotated"] }.map { |cycle| cycle["code"] }
  packs = get_all_packs()
  packs.select { |pack| active_cycles.include? pack["cycle_code"] }.map { |pack| pack["code"] }
end

def download_decks(days)
  all_decks = []
  yesterday = Date.today - 1
  days.times do |i|
    date = yesterday - i
    decks = get_decks_by_date(date)
    all_decks.push(*decks)
  end
  return all_decks
end

def standard?(deck)
  cards = deck["cards"]
  cards.any? do |card, count|
    data = get_card(card)
    pack = data["pack_code"]
    !STARTUP.include?(pack) && STANDARD.include?(pack)
  end
end

def group_decks(decks)
  result = {}
  decks.each do |deck|
    id = deck["cards"].find do |card, count|
      data = get_card(card)
      data["type_code"] == "identity"
    end
    card = get_card(id[0])
    faction = card["faction_code"]
    side = card["side_code"]
    if !result.key?(faction)
      result[faction] = []
    end
    result[faction].push(deck)
    if !result.key?(side)
      result[side] = []
    end
    result[side].push(deck)
  end
  return result
end

def output_group(group, cards)
  template = "templates/template.html"
  template = File.read template
  template = template.split("##BODY##")
  first = template[0]
  second = template[1]

  filename = "html/" + group + ".html"
  puts "outputing #{filename}..."
  File.open(filename, "w") do |f|
    f.write(first)
    f.write("<div class=\"box\"><div>")
    f.write("<h1>#{group}</h1>")
    f.write("<table>")
    if group == "runner" || group == "corp"
      cards = cards.take(100)
    else
      cards = cards.take(cards.size / 2)
    end
    cards.each_slice(4) do |chunk|
      f.write("<tr>")
      chunk.each do |card|
        f.write("<td>")
        f.write("<a href=\"#{card[:nrdb]}\">")
        f.write("<img src=\"#{card[:src]}\" alt=\"#{card[:alt]}\" title=\"#{card[:alt]}\">")
        f.write("</a>")
        f.write("</td>")
      end
      f.write("</tr>")
    end
    f.write("</table><div></div")
    f.write(second)
  end
end

def output_toc(decks_count, newest, oldest)
  template = "templates/toc-template.html"
  template = File.read template
  template = template.sub("##DECKS_COUNT##", decks_count.to_s)
  template = template.sub("##NEWEST##", newest.strftime("%b %d, %Y"))
  template = template.sub("##OLDEST##", oldest.strftime("%b %d, %Y"))
  File.open("index.html", "w") do |f|
    f.write(template)
  end
end

def main()
  puts "getting active packs..."
  days = 105
  stats_by_group = Hash.new do |h,k|
    stats = Hash.new { |h,k| h[k] = 0 }
    h[k] = stats
  end

  printf "downloading decks..."
  all_decks = download_decks(days)
  printf "got #{all_decks.size} decks from past #{days} days.\n"

  printf "filtering standard decks..."
  standard_decks = all_decks.select { |deck| standard? deck }
  printf "got #{standard_decks.size} standard decks.\n"

  puts "grouping decks..."
  grouped = group_decks(standard_decks)

  puts "counting cards..."
  grouped.each do |group, decks|
    stats = stats_by_group[group]

    decks.each do |deck|
      cards = deck["cards"]
      cards.each do |card, count|
        stats[card] = stats[card] + 1
      end
    end
  end

  cards_by_group = {}
  stats_by_group.each do |group, stats|
    cards = []
    sorted = stats.sort_by { |card, count| count }.reverse
    sorted.each do |card, count|
      data = get_card(card)
      pack = data["pack_code"]
      title =  CGI.escapeHTML(data["title"])
      faction = data["faction_code"]
      identity = data["type_code"] == "identity"
      match_faction = group == "runner" || group == "corp" || group == faction
      if !identity && STANDARD.include?(pack) && !STARTUP.include?(pack) && match_faction
        src = IMG_URL.sub("{code}", card)
        nrdb = NRDB_URL.sub("{code}", card)
        cards << { :code => card.to_i, :src => src, :nrdb => nrdb, :alt => "#{title}, #{count} decks" }
      end
    end
    cards_by_group[group] = cards
  end

  cards_by_group.each { |group, cards| output_group(group, cards) }
  yesterday = Date.today - 1
  output_toc(standard_decks.size, yesterday, yesterday - days)
end

#puts get_card(33048)

main()
