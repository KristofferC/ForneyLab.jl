export generateSchedule!, generateSchedule

function generateSchedule(outbound_interface::Interface, graph::FactorGraph=getCurrentGraph(); args...)
    # Generate a schedule that can be executed to calculate the outbound message on outbound_interface.
    # IMPORTANT: the resulting schedule depends on the current messages stored in the factor graph.
    # The same graph with different messages being present can (and probably will) result in a different schedule.
    # When a lot of iterations of the same message passing schedule are required, it can be very beneficial
    # to generate the schedule just once using this function, and then execute the same schedule over and over.
    # This prevents having to generate the same schedule in every call to calculateMessage!().
    return convert_to_schedule(generateScheduleByDFS(outbound_interface, Array(Interface, 0), Array(Interface, 0), graph; args...))
end
function generateSchedule!(outbound_interface::Interface, graph::FactorGraph=getCurrentGraph(); args...)
    schedule = generateSchedule(outbound_interface, graph; args...)
    return graph.edge_to_subgraph[outbound_interface.edge].internal_schedule = schedule
end

function generateSchedule(partial_schedule::Schedule, graph::FactorGraph=getCurrentGraph(); args...)
    # Generate a complete schedule based on partial_schedule.
    # A partial schedule only defines the order of a subset of all required messages.
    # This function will find a valid complete schedule that satisfies the partial schedule.
    # IMPORTANT: the resulting schedule depends on the current messages stored in the factor graph.
    # The same graph with different messages being present can (and probably will) result in a different schedule.
    # When a lot of iterations of the same message passing schedule are required, it can be very beneficial
    # to generate the schedule just once using this function, and then execute the same schedule over and over.
    # This prevents having to generate the same schedule in every call to calculateMessage!().

    # Verify that all entries in partial_schedule belong to the same subgraph
    (length(partial_schedule) > 0) || error("Partial schedule should contain at least one entry")
    
    for schedule_entry in partial_schedule
        is(graph.edge_to_subgraph[schedule_entry.interface.edge], graph.edge_to_subgraph[partial_schedule[1].interface.edge]) || error("Not all interfaces in your partial schedule belong to the same subgraph")
    end

    schedule = Array(Interface, 0)
    for schedule_entry in partial_schedule
        schedule = generateScheduleByDFS(schedule_entry.interface, schedule, Array(Interface, 0), graph; args...)
    end

    return convert_to_schedule(schedule)
end
generateSchedule(partial_list::Array{Interface, 1}, graph::FactorGraph=getCurrentGraph(); args...) = generateSchedule(convert_to_schedule(partial_list), graph; args...)
function generateSchedule!(partial_schedule::Schedule, graph::FactorGraph=getCurrentGraph(); args...)
    schedule = generateSchedule(partial_schedule, graph; args...)
    return graph.edge_to_subgraph[partial_schedule[1].edge].internal_schedule = schedule
end
generateSchedule!(partial_list::Array{Interface, 1}, graph::FactorGraph=getCurrentGraph(); args...) = generateSchedule!(convert_to_schedule(partial_list), graph; args...)

function generateSchedule!(subgraph::Subgraph, graph::FactorGraph=getCurrentGraph())
    # Generate an internal and external schedule for the subgraph

    # Set external schedule with nodes (g) connected to external edges
    subgraph.external_schedule = getNodesConnectedToExternalEdges(graph, subgraph)

    schedule_for_univariate = Array(Interface, 0)
    internal_schedule = Array(Interface, 0)
    subgraph.internal_schedule = Array(ScheduleEntry, 0)
    # The internal schedule makes sure that incoming internal messages over internal edges connected to nodes (g) are present
    for g_node in subgraph.external_schedule # All nodes that are connected to at least one external edge
        outbound_interfaces = Array(Interface, 0) # Array that holds required outbound for the case of one internal edge connected to g_node
        for interface in g_node.interfaces
            if interface.edge in subgraph.internal_edges # edge carries incoming internal message
                # Store outbound interfaces for check later on
                if !(interface in internal_schedule) && !(interface in schedule_for_univariate)
                    push!(outbound_interfaces, interface) # If we were to add the outbound to the schedule (for the case of univariate q), this is the one
                end

                # Extend internal_schedule to calculate the inbound message on interface
                try
                    internal_schedule = generateScheduleByDFS(interface.partner, internal_schedule, Array(Interface, 0), graph, stay_in_subgraph=true)
                catch
                    error("Cannot generate internal schedule for possibly loopy subgraph with internal edge $(interface.edge).")
                end
            end
        end
        
        # For the case that g_node is connected to one internal edge,
        # the calculation reduces to the naive vmp update which requires the outbound (Dauwels, 2007)
        if length(outbound_interfaces) == 1
            push!(schedule_for_univariate, outbound_interfaces[1])
        end
    end

    # Make sure that messages are propagated to the timewraps
    schedule_for_time_wraps = Array(Interface, 0)
    for (from_node, to_node) in graph.time_wraps
        if graph.edge_to_subgraph[from_node.out.edge] == subgraph # Timewrap is the responsibility of this subgraph
            #try
                time_wrap_schedule = generateScheduleByDFS(from_node.out.partner, Array(Interface, 0), Array(Interface, 0), graph, stay_in_subgraph=true)
            #catch
            #    error("Cannot generate time wrap update schedule for loopy subgraph with internal edge $(from_node.out.edge).")
            #end
            schedule_for_time_wraps = [schedule_for_time_wraps, time_wrap_schedule]
        end
    end
    
    # Schedule for univariate comes after internal schedule, because it can depend on inbounds
    subgraph.internal_schedule = convert_to_schedule(unique([internal_schedule, schedule_for_univariate, schedule_for_time_wraps]))
    
    return subgraph
end

function generateSchedule!(graph::FactorGraph=getCurrentGraph())
    for subgraph in graph.factorization
        generateSchedule!(subgraph, graph)
    end
    return graph
end

function generateScheduleByDFS(outbound_interface::Interface, backtrace::Array{Interface, 1}=Array(Interface, 0), call_list::Array{Interface, 1}=Array(Interface, 0), graph::FactorGraph=getCurrentGraph(); stay_in_subgraph=false)
    # This is a private function that performs a search through the factor graph to generate a schedule.
    # IMPORTANT: the resulting schedule depends on the current messages stored in the factor graph.
    # This is a recursive implementation of DFS. The recursive calls are stored in call_list.
    # backtrace will hold the backtrace.
    node = outbound_interface.node

    # Apply stopping condition for recursion. When the same interface is called twice, this is indicative of an unbroken loop.
    if outbound_interface in call_list
        # Notify the user to break the loop with an initial message
        error("Loop detected around $(outbound_interface) Consider setting an initial message somewhere in this loop.")
    elseif outbound_interface in backtrace
        # This outbound_interface is already in the schedule
        return backtrace
    else # Stopping condition not satisfied
        push!(call_list, outbound_interface)
    end

    # Check all inbound messages on the other interfaces of the node
    outbound_interface_id = 0
    for interface_id = 1:length(node.interfaces)
        interface = node.interfaces[interface_id]
        if is(interface, outbound_interface)
            outbound_interface_id = interface_id
        end
        if (!isdefined(outbound_interface, :dependencies) && outbound_interface_id==interface_id) || # Outbound is inbound and not specified as required
           (isdefined(outbound_interface, :dependencies) && !(interface in outbound_interface.dependencies)) || # Inbound specified as not required
           (stay_in_subgraph && graph.edge_to_subgraph[outbound_interface.edge] != graph.edge_to_subgraph[interface.edge]) # Internal subgraph schedule generation and edges are on different subgraphs
            continue
        end
        (interface.partner != nothing) || error("Disconnected interface should be connected: interface #$(interface_id) of $(typeof(node)) $(node.name)")

        if interface.partner.message == nothing # Required message missing.
            if !(interface.partner in backtrace) # Don't recalculate stuff that's already in the schedule.
                # Recursive call
                printVerbose("Recursive call of generateSchedule! on node $(typeof(interface.partner.node)) $(interface.partner.node.name)")
                generateScheduleByDFS(interface.partner, backtrace, call_list, graph, stay_in_subgraph=stay_in_subgraph)
            end
        end
    end

    # Update call_list and backtrace
    pop!(call_list)

    return push!(backtrace, outbound_interface)
end   