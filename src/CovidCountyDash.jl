module CovidCountyDash
import HTTP, CSV
using Dash, DashCoreComponents, DashHtmlComponents
using DataFrames, Dates, PlotlyBase, Statistics
using Base: splat

export download_and_preprocess, create_app, HTTP, DataFrame, run_server

function download_and_preprocess(popfile)
    d = CSV.read(IOBuffer(String(HTTP.get("https://raw.githubusercontent.com/nytimes/covid-19-data/master/us-counties.csv").body)), DataFrame, normalizenames=true)
    pop = CSV.read(popfile, DataFrame)
    dd = leftjoin(d, pop, on=:fips, matchmissing=:equal)
    # # New York City
    # All cases for the five boroughs of New York City (New York, Kings, Queens, Bronx and Richmond counties) are assigned to a single area called New York City.
    dd[(dd.state .== "New York") .& (dd.county .== "New York City"), :pop] .=
        sum(pop.pop[pop.fips .∈ ((36061, # New York
                                 36047, # Kings
                                 36081, # Queens
                                 36005, # Bronx
                                 13245, # Richmond
                                 ),)])
    # # Kansas City, Mo
    # Four counties (Cass, Clay, Jackson and Platte) overlap the municipality of Kansas City, Mo. The cases and deaths that we show for these four counties are only for the portions exclusive of Kansas City. Cases and deaths for Kansas City are reported as their own line.
    mo = dd.state .== "Missouri"
    # 2018 estimated pop for KCMO: https://www.census.gov/quickfacts/fact/table/kansascitycitymissouri/PST045218
    dd[mo .& (dd.county .== "Kansas City"), :pop] .= 491918
    # subtract out 2018 estimates of KCMO from counties: https://www.marc.org/Data-Economy/Metrodataline/Population/Current-Population-Data
    dd[mo .& (dd.county .== "Cass"), :pop] .-= 201
    dd[mo .& (dd.county .== "Clay"), :pop] .-= 126460
    dd[mo .& (dd.county .== "Jackson"), :pop] .-= 315801
    dd[mo .& (dd.county .== "Platte"), :pop] .-= 49456

    # # Joplin, MO
    # Dammit NYT. "Starting June 25, cases and deaths for Joplin are reported separately from Jasper and Newton counties. The cases and deaths reported for those counties are only for the portions exclusive of Joplin. Joplin cases and deaths previously appeared in the counts for those counties or as Unknown."
    # https://www.census.gov/quickfacts/fact/table/joplincitymissouri,US/PST045219
    dd[mo .& (dd.county .== "Joplin"), :pop] .= 50798
    # Very little of Joplin is in Newton; cannot find exact figures. Guess a 95/5 split?
    dd[mo .& (dd.county .== "Jasper"), :pop] .-= 50798 * 95 ÷ 100
    dd[mo .& (dd.county .== "Newton"), :pop] .-= 50798 *  5 ÷ 100

    # Set all unknown counties to 0
    dd[dd.county .== "Unknown", :pop] .= 0
    return dd
end

# utilities to compute the cases by day, subseted and aligned
isset(x) = x !== nothing && !isempty(x)
rolling(f, v, n) = n == 1 ? v : [f(@view v[max(firstindex(v),i-n+1):i]) for i in eachindex(v)]
function subset(df, states, counties)
    mask = isset(counties) ? (df.county .∈ (counties,)) .& (df.state .∈ (states,)) : df.state .∈ (states,)
    return combine(groupby(df[mask, :], :date), :cases=>sum, :deaths=>sum, :pop=>sum, renamecols=false)
end
function precompute(df, states, counties; type=:cases, roll=1, popnorm=false)
    !isset(states) && return DataFrame(values=Int[],diff=Int[],dates=Date[],location=String[])
    subdf = subset(df, states, counties)
    vals = float.(subdf[!, type])
    dates = subdf.date
    if popnorm
        vals .*= 100 ./ subdf.pop
    end
    loc = !isset(counties) ?
        (length(states) <= 2 ? join(states, " + ") : "$(states[1]) + $(length(states)-1) other states") :
        (length(counties) <= 2 ? join(counties, " + ") * ", " * states[] :
            "$(counties[1]), $(states[]) + $(length(counties)-1) other counties")
    return DataFrame(values=vals, dates=dates, diff=[missing; rolling(mean, diff(vals), roll)], location=loc)
end
# Given a state, list its counties
function counties(df, states)
    !isset(states) && return NamedTuple{(:label, :value),Tuple{String,String}}[]
    if length(states) == 1
        [(label=c, value=c) for c in sort!(unique(df[df.state .== states[1], :county]))]
    else
        # We don't keep the state/county pairings straight so disable it
        # [(label="$c, $s", value=c) for s in states for c in sort!(unique(df[df.state .== s, :county]))]
        NamedTuple{(:label, :value),Tuple{String,String}}[]
    end
end
# put together the plot given a sequence of alternating state/county pairs
function plotit(df, value, type, roll, checkopts, pp...)
    roll = something(roll, 1)
    logy = checkopts === nothing ? false : "logy" in checkopts
    popnorm = checkopts === nothing ? false : "popnorm" in checkopts
    data = reduce(vcat, [precompute(df, state, county, type=Symbol(type), roll=roll, popnorm=popnorm) for (state, county) in Iterators.partition(pp, 2)])
    data.text = Dates.format.(data.dates, "U d")
    layout = Layout(
        xaxis_title = "Date",
        yaxis_title = value == "values" ? "Total confirmed $type" :
                      roll > 1 ? "Average daily $type (rolling $roll-day mean)" : "Number of daily $type",
        xaxis = Dict(),
        yaxis_ticksuffix = popnorm ? "%" : "",
        hovermode = "closest",
        title = string(value == "values" ? "Total " : "Daily " , "Confirmed ", uppercasefirst(type)),
        height = "40%",
        yaxis_type= logy ? "log" : "linear",
        margin=(l=220,),
    )
    isempty(data) && return Plot(data, layout)
    return Plot(data, layout,
        x = :dates,
        y = Symbol(value),
        text = :text,
        group = :location,
        hovertemplate = "%{text}: %{y}",
        mode = "lines",
    )
end

function create_app(df;max_lines=6)
    states = sort!(unique(df.state))
    app = dash(external_stylesheets=["https://stackpath.bootstrapcdn.com/bootstrap/4.4.1/css/bootstrap.min.css"])
    app.title = "🦠 COVID-19 Tracked by US County"
    app.layout =
        html_div(style=(padding="2%",), [
            html_h1("🦠 COVID-19 Tracked by US County", style=(textAlign = "center",)),
            html_div(style=(width="60%",margin="auto", textAlign="center"), [
                "Visualization of ",
                html_a("data", href="https://github.com/nytimes/covid-19-data"),
                " from ",
                html_a("The New York Times", href="https://www.nytimes.com/interactive/2020/us/coronavirus-us-cases.html"),
                ", based on reports from state and local health agencies",
                html_p("Loaded data through $(Dates.format(maximum(df.date), "U d"))",
                    style=(height="2rem", lineHeight="2rem",margin="0")),
                ]),
            html_div(className="row", [
                html_div(className="col-8",
                    html_table(style=(width="100%",),
                        vcat(html_tr([html_th("State",style=(width="40%",)),
                                      html_th("County",style=(width="60%",))]),
                             [html_tr([html_td(dcc_dropdown(id="state-$n", options=[(label=s, value=s) for s in states], multi=true), style=(width="40%",)),
                                      html_td(dcc_dropdown(id="county-$n", options=[], multi=true), style=(width="60%",))], id="scrow-$n")
                              for n in 1:max_lines])
                    )
                ),
                html_div(className="col-4", [
                    html_b("Options"),
                    dcc_radioitems(id="type", labelStyle=(display="block",),
                        options=[
                            (label="Confirmed positive cases", value="cases"),
                            (label="Confirmed deaths", value="deaths")],
                        value="cases"),
                    html_hr(style=(margin=".25em",)),
                    dcc_radioitems(id="values", labelStyle=(display="block",),
                        options=[
                            (label="Cumulative", value="values"),
                            (label="New daily cases", value="diff")],
                        value="diff"),
                    html_div(id="smoothing_selector", style=(visibility="visible", display="block"), [
                        html_span("Rolling", style=(var"padding-left"="1.5em",)),
                        dcc_input(id="roll", type="number", min=1, max=14, step=1, value=7, style=(margin="0 .5em 0 .5em",)),
                        html_span("day mean")
                    ]),
                    html_hr(style=(margin=".25em",)),
                    dcc_checklist(id="checkopts", labelStyle=(display="block",),
                        options=[
                            (label="Normalize by population", value="popnorm"),
                            (label="Use logarithmic y-axis", value="logy")
                        ])
                ])
            ]),
            html_div(dcc_graph(id = "theplot", figure=Plot()), style = (width="80%", display="block", margin="auto")),
            html_br(),
            html_span([html_a("Code source", href="https://github.com/mbauman/CovidCountyDash.jl"),
                " (",  html_a("Julia", href="https://julialang.org"),
                " + ", html_a("Plotly Dash", href="https://plotly.com/dash/"),
                " + ", html_a("Dash.jl", href="https://juliahub.com/ui/Packages/Dash/oXkBb"),
                ")"],
                style=(textAlign = "center", display = "block"))
        ])

    hide_missing_row(s, c) = !isset(s) && !isset(c) ? (display="none",) : (display="table-row",)
    for n in 2:max_lines
        callback!(hide_missing_row, app, Output("scrow-$n", "style"), [Input("state-$n", "value"), Input("state-$(n-1)", "value")])
    end
    for n in 1:max_lines
        callback!(x->counties(df, x), app, Output("county-$n", "options"), Input("state-$n", "value"))
        callback!(x->nothing, app, Output("county-$n", "value"), Input("state-$n", "value"))
    end
    callback!((args...)->plotit(df, args...), app, Output("theplot", "figure"),
        splat(Input).([("values", "value"); ("type", "value"); ("roll", "value"); ("checkopts", "value");
                [("$t-$n", "value") for n in 1:max_lines for t in (:state, :county)]]))
    callback!(identity, app, Output("cases_or_deaths","children"), Input("type","value"))
    callback!(app, Output("values","options"), Input("type","value")) do type
        return [(label="Cumulative", value="values"), (label="New daily $(type)", value="diff")]
    end
    callback!(app, Output("smoothing_selector","style"), Input("values","value")) do value
        if value == "diff"
            return (visibility="visible", display="block")
        else
            return (visibility="hidden", display="none")
        end
    end
    return app
end
end