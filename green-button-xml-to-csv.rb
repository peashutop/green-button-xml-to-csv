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

# From https://utilityapi.com/docs/greenbutton/xml
UOM_MAP = {
  '38' => 'Watts',
  '72' => 'Watt-hours'
}

METER_READING_KIND_MAP = {
  '8' => 'demand',
  '12' => 'energy'
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
      uom:  text_or_nil(rt, './uom'),
      kind: text_or_nil(rt, './kind')
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
    next unless rt && (rt[:uom] == '38' || rt[:uom] == '72')
    unit_of_measurement_code = rt[:uom]
    unit_of_measurement_name = UOM_MAP[unit_of_measurement_code]
    kind_name = METER_READING_KIND_MAP[rt[:kind]]

    ib.xpath('./IntervalReading').each do |ir|
      start_epoch = text_or_nil(ir, './timePeriod/start')&.to_i
      duration_seconds  = text_or_nil(ir, './timePeriod/duration')&.to_i
      end_epoch   = start_epoch + duration_seconds
      value = text_or_nil(ir, './value')&.to_i
            
      rows << [
        start_epoch,
        end_epoch,        
        value,        
        unit_of_measurement_name,
        kind_name
      ]
    end
  end
end

headers = [
  'start_epoch',
  'end_epoch',  
  'value',  
  'unit',
  'kind'
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
