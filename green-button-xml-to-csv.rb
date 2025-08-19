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

# ESPI/NAESB namespace
ESPI_NS = 'http://naesb.org/espi'

# ESPI UOM codes we care about
UOM_MAP = {
  '38' => 'Wh' # Watt-hour (typical for interval energy)
}

def text_or_nil(node, xpath, ns=nil)
  n = node.at_xpath(xpath, ns)
  n ? n.text.strip : nil
end

doc = File.open(INPUT) { |f| Nokogiri::XML(f) }
doc.remove_namespaces!

# Collect ReadingType(s) (often just one)
reading_types = []
doc.xpath('//ReadingType').each do |rt|
  reading_types << {
    uom:                     text_or_nil(rt, './uom'),
    power_of_ten:            (text_or_nil(rt, './powerOfTenMultiplier') || '0'),
    interval_length:         text_or_nil(rt, './intervalLength'),
    accumulation_behaviour:  text_or_nil(rt, './accumulationBehaviour')
  }
end

# Fallback defaults if none found
default_rt = {
  uom: '38', # assume Wh
  power_of_ten: '0',
  interval_length: nil,
  accumulation_behaviour: nil
}

active_rt  = reading_types.first || default_rt
uom_code   = active_rt[:uom]
uom_name   = UOM_MAP[uom_code] || "code_#{uom_code}"
p10        = active_rt[:power_of_ten].to_i
scale      = 10.0 ** p10

# Optional LocalTimeParameters (for reference; we keep CSV in UTC)
ltp        = doc.at_xpath('//LocalTimeParameters')
tz_offset  = ltp && text_or_nil(ltp, './tzOffset')&.to_i
dst_offset = ltp && text_or_nil(ltp, './dstOffset')&.to_i

rows = []

doc.xpath('//IntervalBlock').each do |block|
  block_duration = text_or_nil(block, './interval/duration')&.to_i
  block_start    = text_or_nil(block, './interval/start')&.to_i

  block.xpath('./IntervalReading').each do |ir|
    start_epoch = text_or_nil(ir, './timePeriod/start')&.to_i
    duration_s  = text_or_nil(ir, './timePeriod/duration')&.to_i
    value_raw   = text_or_nil(ir, './value')&.to_i

    # Apply powerOfTenMultiplier
    scaled_value = value_raw * scale # still in the ReadingType unit

    value_wh  = nil
    value_kwh = nil
    avg_kw    = nil

    if uom_code == '38' # Wh
      value_wh  = scaled_value
      value_kwh = value_wh / 1000.0
      if duration_s && duration_s > 0
        # Average demand over the interval in kW
        avg_kw = value_kwh * 3600.0 / duration_s
      end
    end

    start_utc = Time.at(start_epoch).utc
    end_utc   = Time.at(start_epoch + duration_s).utc

    rows << [
      start_utc.iso8601,
      end_utc.iso8601,
      duration_s,
      value_raw,
      p10,
      uom_code,
      uom_name,
      (value_wh  && format('%.3f', value_wh)),
      (value_kwh && format('%.6f', value_kwh)),
      (avg_kw    && format('%.6f', avg_kw)),
      block_start,
      block_duration,
      tz_offset,
      dst_offset
    ]
  end
end

headers = [
  'start_utc',
  'end_utc',
  'duration_seconds',
  'value_raw',
  'power_of_ten_multiplier',
  'uom_code',
  'uom_name',
  'value_Wh',
  'value_kWh',
  'avg_kW',
  'block_start_epoch',
  'block_duration_seconds',
  'tz_offset_seconds',
  'dst_offset_seconds'
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
