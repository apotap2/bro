##! This is the implementation of the metrics framework.

@load base/frameworks/notice

module Metrics;

export {
	redef enum Log::ID += { METRICS };
	
	type ID: enum {
		NOTHING,
	};
	
	## The default interval used for "breaking" metrics and writing the 
	## current value to the logging stream.
	const default_break_interval = 15mins &redef;
	
	## This is the interval for how often notices will happen after they have
	## already fired.
	const renotice_interval = 1hr &redef;
	
	type Index: record {
		## Host is the value to which this metric applies.
		host:         addr &optional;
		
		## A non-address related metric or a sub-key for an address based metric.
		## An example might be successful SSH connections by client IP address
		## where the client string would be the index value.
		## Another example might be number of HTTP requests to a particular
		## value in a Host header.  This is an example of a non-host based
		## metric since multiple IP addresses could respond for the same Host
		## header value.
		str:        string &optional;
		
		## The CIDR block that this metric applies to.  This is typically
		## only used internally for host based aggregation.
		network:      subnet &optional;
	} &log;
	
	type Info: record {
		ts:           time   &log;
		metric_id:    ID     &log;
		filter_name:  string &log;
		index:        Index  &log;
		value:        count  &log;
	};
	
	# TODO: configure a metrics filter logging stream to log the current
	#       metrics configuration in case someone is looking through
	#       old logs and the configuration has changed since then.
	type Filter: record {
		## The :bro:type:`Metrics::ID` that this filter applies to.
		id:                ID                      &optional;
		## The name for this filter so that multiple filters can be
		## applied to a single metrics to get a different view of the same
		## metric data being collected (different aggregation, break, etc).
		name:              string                  &default="default";
		## A predicate so that you can decide per index if you would like
		## to accept the data being inserted.
		pred:              function(index: Index): bool &optional;
		## Global mask by which you'd like to aggregate traffic.
		aggregation_mask:  count                   &optional;
		## This is essentially a mapping table between addresses and subnets.
		aggregation_table: table[subnet] of subnet &optional;
		## The interval at which the metric should be "broken" and written
		## to the logging stream.  The counters are also reset to zero at 
		## this time so any threshold based detection needs to be set to a 
		## number that should be expected to happen within this period.
		break_interval:    interval                &default=default_break_interval;
		## This determines if the result of this filter is sent to the metrics
		## logging stream.  One use for the logging framework is as an internal
		## thresholding and statistics gathering utility that is meant to
		## never log but rather to generate notices and derive data.
		log:               bool                    &default=T;
		## If this and a $notice_threshold value are set, this notice type
		## will be generated by the metrics framework.
		note:              Notice::Type            &optional;
		## A straight threshold for generating a notice.
		notice_threshold:  count                   &optional;
		## A series of thresholds at which to generate notices.
		notice_thresholds: vector of count         &optional;
		## How often this notice should be raised for this metric index.  It 
		## will be generated everytime it crosses a threshold, but if the 
		## $break_interval is set to 5mins and this is set to 1hr the notice
		## only be generated once per hour even if something crosses the
		## threshold in every break interval.
		notice_freq:       interval                &optional;
	};
	
	global add_filter: function(id: ID, filter: Filter);
	global add_data: function(id: ID, index: Index, increment: count);
	global index2str: function(index: Index): string;
	
	# This is the event that is used to "finish" metrics and adapt the metrics
	# framework for clustered or non-clustered usage.
	global log_it: event(filter: Filter);
	
	global log_metrics: event(rec: Info);
}

redef record Notice::Info += {
	metric_index: Index &log &optional;
};

global metric_filters: table[ID] of vector of Filter = table();
global filter_store: table[ID, string] of Filter = table();

type MetricTable: table[Index] of count &default=0;
# This is indexed by metric ID and stream filter name.
global store: table[ID, string] of MetricTable = table() &default=table();

# This function checks if a threshold has been crossed and generates a 
# notice if it has.  It is also used as a method to implement 
# mid-break-interval threshold crossing detection for cluster deployments.
global check_notice: function(filter: Filter, index: Index, val: count): bool;

# This is hook for watching thresholds being crossed.  It is called whenever
# index values are updated and the new val is given as the `val` argument.
global data_added: function(filter: Filter, index: Index, val: count);

# This stores the current threshold index for filters using the
# $notice_threshold and $notice_thresholds elements.
global thresholds: table[ID, string, Index] of count = {} &create_expire=renotice_interval &default=0;

event bro_init() &priority=5
	{
	Log::create_stream(METRICS, [$columns=Info, $ev=log_metrics]);
	}

function index2str(index: Index): string
	{
	local out = "";
	if ( index?$host )
		out = fmt("%shost=%s", out, index$host);
	if ( index?$network )
		out = fmt("%s%snetwork=%s", out, |out|==0 ? "" : ", ", index$network);
	if ( index?$str )
		out = fmt("%s%sstr=%s", out, |out|==0 ? "" : ", ", index$str);
	return fmt("metric_index(%s)", out);
	}
	
function write_log(ts: time, filter: Filter, data: MetricTable)
	{
	for ( index in data )
		{
		local val = data[index];
		local m: Info = [$ts=ts,
		                 $metric_id=filter$id,
		                 $filter_name=filter$name,
		                 $index=index,
		                 $value=val];
		
		if ( filter$log )
			Log::write(METRICS, m);
		}
	}


function reset(filter: Filter)
	{
	store[filter$id, filter$name] = table();
	}

function add_filter(id: ID, filter: Filter)
	{
	if ( filter?$aggregation_table && filter?$aggregation_mask )
		{
		print "INVALID Metric filter: Defined $aggregation_table and $aggregation_mask.";
		return;
		}
	if ( [id, filter$name] in store )
		{
		print fmt("INVALID Metric filter: Filter with name \"%s\" already exists.", filter$name);
		return;
		}
	if ( filter?$notice_threshold && filter?$notice_thresholds )
		{
		print "INVALID Metric filter: Defined both $notice_threshold and $notice_thresholds";
		return;
		}
	
	if ( ! filter?$id )
		filter$id = id;
	
	if ( id !in metric_filters )
		metric_filters[id] = vector();
	metric_filters[id][|metric_filters[id]|] = filter;

	filter_store[id, filter$name] = filter;
	store[id, filter$name] = table();
	
	schedule filter$break_interval { Metrics::log_it(filter) };
	}
	
function add_data(id: ID, index: Index, increment: count)
	{
	if ( id !in metric_filters )
		return;
	
	local filters = metric_filters[id];
	
	# Try to add the data to all of the defined filters for the metric.
	for ( filter_id in filters )
		{
		local filter = filters[filter_id];
		
		# If this filter has a predicate, run the predicate and skip this
		# index if the predicate return false.
		if ( filter?$pred && ! filter$pred(index) )
			next;
		
		if ( index?$host )
			{
			if ( filter?$aggregation_mask )
				{
				index$network = mask_addr(index$host, filter$aggregation_mask);
				delete index$host;
				}
			else if ( filter?$aggregation_table )
				{
				index$network = filter$aggregation_table[index$host];
				delete index$host;
				}
			}
		
		local metric_tbl = store[id, filter$name];
		if ( index !in metric_tbl )
			metric_tbl[index] = 0;
		metric_tbl[index] += increment;
		
		data_added(filter, index, metric_tbl[index]);
		}
	}

function check_notice(filter: Filter, index: Index, val: count): bool
	{
	if ( (filter?$notice_threshold &&
	      [filter$id, filter$name, index] !in thresholds &&
	      val >= filter$notice_threshold) ||
	     (filter?$notice_thresholds &&
	      |filter$notice_thresholds| <= thresholds[filter$id, filter$name, index] &&
	      val >= filter$notice_thresholds[thresholds[filter$id, filter$name, index]]) )
		return T;
	else
		return F;
	}
		
function do_notice(filter: Filter, index: Index, val: count)
	{
	# We include $peer_descr here because the a manager count have actually 
	# generated the notice even though the current remote peer for the event 
	# calling this could be a worker if this is running as a cluster.
	local n: Notice::Info = [$note=filter$note, 
	                         $n=val, 
	                         $metric_index=index, 
	                         $peer_descr=peer_description];
	n$msg = fmt("Threshold crossed by %s %d/%d", index2str(index), val, filter$notice_threshold);
	if ( index?$str )
		n$sub = index$str;
	if ( index?$host )
		n$src = index$host;
	# TODO: not sure where to put the network yet.
	
	NOTICE(n);
	
	# This just needs set to some value so that it doesn't refire the 
	# notice until it expires from the table or it crosses the next 
	# threshold in the case of vectors of thresholds.
	++thresholds[filter$id, filter$name, index];
	}
