/*
 * Functions used for FLOT charts
 * Copyright (c) 2013, AllWorldIT
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
 *
 */


// Function to format thousands with , and add Kbps
function awit_flot_format_bandwidth(value, axis) {
	return awit_flot_format_thousands(value,axis) + ' Kbps';
}


// Function to format thousands
function awit_flot_format_thousands(value, axis) {
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


// Function draw a graph
function awit_flot_draw_graph(options) {

	// Setting up the graph here
	var baseOptions = {

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
			tickColor: "#f9f9f9",
			borderWidth: 1
		},

		legend: {
			labelBoxBorderColor: "#aaa"
		},

		xaxes: [
			{
				mode: "time",

				tickSize: [60, "second"],

				tickFormatter: function (v, axis) {
					var date = new Date(v);

					if (date.getSeconds() % 5 == 0) {
						var hours = date.getHours() < 10 ? "0" + date.getHours() : date.getHours();
						var minutes = date.getMinutes() < 10 ? "0" + date.getMinutes() : date.getMinutes();
						var seconds = date.getSeconds() < 10 ? "0" + date.getSeconds() : date.getSeconds();

						return hours + ":" + minutes + ":" + seconds;
					} else {
						return "";
					}
				}
			}
		],

		yaxes: [
			{
				min: 0,
				tickFormatter: awit_flot_format_bandwidth
			}
		]
	}

	// Add additional yaxes if needed
	if (options && options.yaxes && options.yaxes.length) {
		for (k = 0; k < options.yaxes.length; k++) {
			if (options.yaxes[k]) {
				baseOptions.yaxes.push(options.yaxes[k]);
			}
		}
	}

	// Load data from ajax
	jQuery.ajax({
		url: options.url,
		dataType: 'json',

		success: function(statsData) {
			plot = null;

			for (i = 0; (i < statsData.length); i++) {
				// Format time to match javascript's epoch in milliseconds
				for (j = 0; j < statsData[i].data.length; j++) {
					d = new Date(statsData[i].data[j][0] * 1000);
					statsData[i].data[j][0] = statsData[i].data[j][0] * 1000;
				}
				// Loop with yaxes
				for (k = 0; k < baseOptions.yaxes.length; k++) {
					// Check if there are labels
					if (baseOptions.yaxes[k].labels && baseOptions.yaxes[k].labels.length) {
						// Loop through labels
						for (l = 0; l < baseOptions.yaxes[k].labels.length; l++) {
							// Check for match
			                if (statsData[i].label == baseOptions.yaxes[k].labels[l]) {
       				            statsData[i].yaxis = k + 1;
	    	    	        }
						}
					}
				}
			}

			if (statsData.length > 0) {
				plot = jQuery.plot(jQuery("#flotCanvas"), statsData, baseOptions);
			}
		}
	});
}


// vim: ts=4
