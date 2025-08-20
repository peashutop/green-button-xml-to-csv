#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Usage:
#   ruby green_button_to_csv.rb input.xml output.csv
#
# If output.csv is omitted, writes to STDOUT.

require 'nokogiri'
require 'csv'
require 'time'

INPUT  = ARGV[0] or abort "Usage: ruby #{$0} input.xml [output.csv]"
OUTPUT = ARGV[1]

# ESPI UOM codes we care about
UOM_MAP = {
  '38' => 'W',  # Watts
  '72' => 'Wh'  # Watt-hours (we skip these lines for now)
}

def text_or_nil(node, xpath)
  n = node.at_xpath(xpath)
  n ? n.text.strip : nil
end

doc = File.open(INPUT) { |f| Nokogiri::XML(f) }
doc.remove_namespaces!

# Collect ReadingType(s) and build id=>ReadingType map
reading_types = {}
doc.xpath('//entry').each do |entry|
  rt = entry.at_xpath('./content/ReadingType')
  if rt
    id = text_or_nil(entry, './id')
    reading_types[id] = {
      uom: text_or_nil(rt, './uom')
    }
  end
end

# Build MeterReading id => ReadingType id map
meter_reading_to_rt = {}
doc.xpath('//entry').each do |entry|
  mr_id = text_or_nil(entry, './id')
  if entry.at_xpath('./content/MeterReading')
    # Find related ReadingType link
    rt_link = entry.xpath('./link[@type="espi-entry/ReadingType"]')&.first
    if rt_link
      href = rt_link['href']
      # Extract ReadingType id from URL
      if href =~ /ReadingType\/(urn:uuid:[^\/]+)/
        rt_id = $1
        meter_reading_to_rt[mr_id] = rt_id
      end
    end
  end
end

rows = []

doc.xpath('//entry').each do |entry|
  ib = entry.at_xpath('./content/IntervalBlock')
  next unless ib
  # Find related MeterReading link
  mr_link = entry.xpath('./link[@type="espi-entry/MeterReading"]')&.first
  next unless mr_link
  mr_href = mr_link['href']
  if mr_href =~ /MeterReading\/(urn:uuid:[^\/]+)/
    mr_id = $1
    rt_id = meter_reading_to_rt[mr_id]
    rt = reading_types[rt_id]
    next unless rt && rt[:uom] == '38'
    uom_code = rt[:uom]
    uom_name = UOM_MAP[uom_code]    
    block_duration = text_or_nil(ib, './interval/duration')&.to_i
    block_start    = text_or_nil(ib, './interval/start')&.to_i
    ib.xpath('./IntervalReading').each do |ir|
      start_epoch = text_or_nil(ir, './timePeriod/start')&.to_i
      duration_s  = text_or_nil(ir, './timePeriod/duration')&.to_i
      value   = text_or_nil(ir, './value')&.to_i
      start_utc = Time.at(start_epoch).utc
      end_utc   = Time.at(start_epoch + duration_s).utc
      rows << [
        start_utc.iso8601,
        end_utc.iso8601,
        duration_s,
        value,        
        uom_code,
        uom_name,      
        block_start,
        block_duration        
      ]
    end
  end
end

headers = [
  'start_utc',
  'end_utc',
  'duration_seconds',
  'value',  
  'uom_code',
  'uom_name',  
  'block_start_epoch',
  'block_duration_seconds',  
]

if OUTPUT
  CSV.open(OUTPUT, 'w', write_headers: true, headers: headers) do |csv|
    rows.each { |r| csv << r }
  end
  warn "Wrote #{rows.size} rows to #{OUTPUT}"
else
  csv = CSV.generate(write_headers: true, headers: headers) do |c|
    rows.each { |r| c << r }
  end
  puts csv
end
