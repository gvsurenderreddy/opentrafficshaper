/*
 * Functions to help create flot graphs
 * Copyright (c) 2013-2014, AllWorldIT
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 *
 */


// Function draw a graph
function awit_flot_draw_graph(options) {

	// Setup default graph options
	var defaults = {

		series: {
			lines: {
				show: true,
				lineWidth: 1,
				fill: true,
				fillColor: {
					colors: [
						{ opacity: 0.1 },
						{ opacity: 0.13 }
					]
				}
			},

			points: {
				show: false,
				lineWidth: 2,
				radius: 3
			},

			shadowSize: 0,
			stack: true
		},

		grid: {
			hoverable: true,
			clickable: false,
			tickColor: "#F9F9F9",
			borderWidth: 1
		},

		legend: {
			labelBoxBorderColor: "#AAAAAA"
		},

		xaxes: [
			{
				mode: "time",

				tickSize: [5, "minute"]
//				tickLength: 10
/*
				tickFormatter: function (v, axis) {
					var date = new Date(v);
					if (date.getSeconds() % 160 == 0) {
					//if (v % m == 0) {
						var hours = date.getHours() < 10 ? "0" + date.getHours() : date.getHours();
						var minutes = date.getMinutes() < 10 ? "0" + date.getMinutes() : date.getMinutes();
						var seconds = date.getSeconds() < 10 ? "0" + date.getSeconds() : date.getSeconds();

						return hours + ":" + minutes + ":" + seconds;
					} else {
						return "";
					}
				}
*/
			}

		],

        yaxes: [
            {
				position: 'left',
                min: 0,
                tickFormatter: _flot_format_bandwidth
            },
			{
				position: 'right',
                min: 0,
				tickDecimals: false
			}
		]
	}

	// Merge our options ontop of our defaults
	var plotOptions = jQuery.extend({},defaults,options);

	// Grab the placeholder
	var placeholder = jQuery('#'+plotOptions.id);

	// Plot the graph, the [] signifies an empty dataset, the data is populated by awitds
	var plot = jQuery.plot(placeholder, [ ], plotOptions);

	return plot;
}


// Function draw pie graph
function awit_flot_draw_pie(options) {

	// Setup default graph options
	var defaults = {
		series: {
			pie: {
				show: true,
				radius: 1,
				label: {
					show: true,
					radius: 3/4,
					formatter: _flot_format_pie_label,
					background: {
						opacity: 0.5,
						color: '#000000'
					}
            	}
			}
		}
	}

	// Merge our options ontop of our defaults
	var plotOptions = jQuery.extend({},defaults,options);

	// Set count to 1 and override timestamp to 1 for all identifiers
	if (typeof(plotOptions.awitds) !== 'undefined') {
		for (var tag in plotOptions.awitds.xaxis) {
			for (var identifier in plotOptions.awitds.xaxis[tag]) {
				plotOptions.awitds.xaxis[tag][identifier].maxCount = 1;
				plotOptions.awitds.xaxis[tag][identifier].overrideTimestamp = 1;
			}
		}
	}

	// Grab the placeholder
	var placeholder = jQuery('#'+plotOptions.id);

	// Plot the graph, the [] signifies an empty dataset, the data is populated by awitds
	var plot = jQuery.plot(placeholder, [ ], plotOptions);

	return plot;
}


// Function to format thousands with , and add Kbps
function _flot_format_bandwidth(value, axis) {
	return _flot_format_thousands(value,axis) + ' Kbps';
}


// Function to format thousands
function _flot_format_thousands(value, axis) {
	// Convert number to string
	value = value.toString();
	// Match on 3 digits
	var R = new RegExp('(-?[0-9]+)([0-9]{3})');
	while(R.test(value)) {
		// Replace market with ,
		value = value.replace(R, '$1,$2');
	}

	return value;
}

function _flot_format_pie_label(label, series) {
	return "<div style='font-size:8pt; text-align:center; padding:2px; color:white;'>" + label + "<br/>" + Math.round(series.percent) + "%</div>";
}



// vim: ts=4
