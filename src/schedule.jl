export ScheduleEntry, Schedule, ExternalSchedule, ==

type ScheduleEntry
    interface::Interface
    summary_operation::ASCIIString # Summary operation for calculating outbound messages. Default is "sum_product"

    function ScheduleEntry(interface::Interface, summary_operation::ASCIIString)
        summary_operation in ["sum_product", "sample"] || error("Unknown summary operation $(summary_operation). Please choose between 'sum_product' and 'sample'.")
        return new(interface, summary_operation)
    end
end
ScheduleEntry(interface::Interface) = ScheduleEntry(interface, "sum_product")

function ==(x::ScheduleEntry, y::ScheduleEntry)
    if is(x, y) return true end
    if x.interface == y.interface && x.summary_operation == y.summary_operation return true end
    return false
end

typealias Schedule Array{ScheduleEntry, 1}
convert_to_schedule(interfaces::Array{Interface, 1}) = [ScheduleEntry(intf) for intf in interfaces] # Convert a list of interfaces to an actual schedule

function show(io::IO, schedule::Schedule)
    # Show schedules in a specific way
    println(io, "Message passing schedule [{node type} {node name}:{outbound iface index} ({outbound iface name})]:")
    for schedule_entry in schedule
        interface = schedule_entry.interface
        summary_operation = schedule_entry.summary_operation
        
        interface_name = (getName(interface)!="") ? "($(getName(interface)))" : ""
        println(io, " $(summary_operation) update at $(typeof(interface.node)) $(interface.node.name):$(findfirst(interface.node.interfaces, interface)) $(interface_name)")
    end
end

typealias ExternalSchedule Array{Node, 1}
function show(io::IO, nodes::Array{Node, 1})
     # Show node array (possibly an external schedule)
    println(io, "Nodes:")
    for entry in nodes
        println(io, "Node $(entry.name) of type $(typeof(entry))")
    end
end