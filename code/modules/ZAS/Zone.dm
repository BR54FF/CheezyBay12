/*

Overview:
	Each zone is a self-contained area where gas values would be the same if tile-based equalization were run indefinitely.
	If you're unfamiliar with ZAS, FEA's air groups would have similar functionality if they didn't break in a stiff breeze.

Class Vars:
	name - A name of the format "Zone [#]", used for debugging.
	invalid - True if the zone has been erased and is no longer eligible for processing.
	needs_update - True if the zone has been added to the update list.
	edges - A list of edges that connect to this zone.
	air - The gas mixture that any turfs in this zone will return. Values are per-tile with a group multiplier.

Class Procs:
	add(turf/simulated/T)
		Adds a turf to the contents, sets its zone and merges its air.

	remove(turf/simulated/T)
		Removes a turf, sets its zone to null and erases any gas graphics.
		Invalidates the zone if it has no more tiles.

	c_merge(zone/into)
		Invalidates this zone and adds all its former contents to into.

	c_invalidate()
		Marks this zone as invalid and removes it from processing.

	rebuild()
		Invalidates the zone and marks all its former tiles for updates.

	add_tile_air(turf/simulated/T)
		Adds the air contained in T.air to the zone's air supply. Called when adding a turf.

	tick()
		Called only when the gas content is changed. Archives values and changes gas graphics.

	dbg_data(mob/M)
		Sends M a printout of important figures for the zone.

*/


/zone
	var/name
	var/invalid = 0
	var/list/contents = list()
	var/list/fire_tiles = list()
	var/needs_update = 0
	var/list/edges = list()
	var/datum/gas_mixture/air = new
	var/list/graphic_add = list()
	var/list/graphic_remove = list()
	var/last_air_temperature = TCMB

/zone/New()
	SSair.add_zone(src)
	air.temperature = TCMB
	air.group_multiplier = 1
	air.volume = CELL_VOLUME

/zone/proc/add(turf/simulated/turf_to_add)
#ifdef ZASDBG
	ASSERT(!invalid)
	ASSERT(istype(turf_to_add))
	ASSERT(!SSair.has_valid_zone(turf_to_add))
#endif

	var/datum/gas_mixture/turf_air = turf_to_add.return_air()
	add_tile_air(turf_air)
	turf_to_add.zone = src
	contents += turf_to_add

	if(turf_to_add.hotspot)
		fire_tiles += turf_to_add
		SSair.active_fire_zones |= src

	turf_to_add.update_graphic(air.graphic)

/zone/proc/remove(turf/simulated/turf_to_remove)
#ifdef ZASDBG
	ASSERT(!invalid)
	ASSERT(istype(turf_to_remove))
	ASSERT(turf_to_remove.zone == src)
	soft_assert(turf_to_remove in contents, "Lists are weird broseph")
#endif
	contents -= turf_to_remove
	fire_tiles -= turf_to_remove
	turf_to_remove.zone = null
	turf_to_remove.update_graphic(graphic_remove = air.graphic)
	if(length(contents))
		air.group_multiplier = length(contents)
	else
		c_invalidate()

/zone/proc/c_merge(zone/into)
#ifdef ZASDBG
	ASSERT(!invalid)
	ASSERT(istype(into))
	ASSERT(into != src)
	ASSERT(!into.invalid)
#endif
	c_invalidate()
	for(var/turf/simulated/inner_turf in contents)
		into.add(inner_turf)
		inner_turf.update_graphic(graphic_remove = air.graphic)
		#ifdef ZASDBG
		inner_turf.dbg(merged)
		CHECK_TICK
		#endif

	//rebuild the old zone's edges so that they will be possessed by the new zone
	for(var/connection_edge/edge in edges)
		if(edge.contains_zone(into))
			continue //don't need to rebuild this edge

		for(var/turf/connecting_turf in edge.connecting_turfs)
			SSair.mark_for_update(connecting_turf)

/zone/proc/c_invalidate()
	invalid = TRUE
	SSair.remove_zone(src)
	#ifdef ZASDBG
	for(var/turf/simulated/inner_turf in contents)
		inner_turf.dbg(invalid_zone)
	#endif

/zone/proc/rebuild()
	if(invalid) return //Short circuit for explosions where rebuild is called many times over.
	c_invalidate()
	for(var/turf/simulated/inner_turf in contents)
		inner_turf.update_graphic(graphic_remove = air.graphic) //we need to remove the overlays so they're not doubled when the zone is rebuilt
		inner_turf.needs_air_update = FALSE //Reset the marker so that it will be added to the list.
		SSair.mark_for_update(inner_turf)

/zone/proc/add_tile_air(datum/gas_mixture/tile_air)
	//air.volume += CELL_VOLUME
	air.group_multiplier = 1
	air.multiply(length(contents))
	air.merge(tile_air)
	air.divide(length(contents) + 1)
	air.group_multiplier = length(contents) + 1

/zone/proc/tick()

	// Update fires.
	if(air.temperature >= PHORON_FLASHPOINT && !(src in SSair.active_fire_zones) && air.check_combustability() && length(contents))
		var/turf/T = pick(contents)
		if(istype(T))
			T.create_fire(vsc.fire_firelevel_multiplier)

	// Update gas overlays.
	if(air.check_tile_graphic(graphic_add, graphic_remove))
		for(var/turf/simulated/T in contents)
			T.update_graphic(graphic_add, graphic_remove)
		graphic_add.Cut()
		graphic_remove.Cut()

	// Update connected edges.
	for(var/connection_edge/E in edges)
		if(E.sleeping)
			E.recheck()

	// Handle condensation from the air.
	for(var/g in air.gas)
		var/product = gas_data.condensation_products[g]
		if(product && air.temperature <= gas_data.condensation_points[g])
			var/condensation_area = air.group_multiplier
			while(condensation_area > 0)
				condensation_area--
				var/turf/flooding = pick(contents)
				var/condense_amt = min(air.gas[g], rand(3,5))
				if(condense_amt < 1)
					break
				air.adjust_gas(g, -condense_amt)
				flooding.add_fluid(condense_amt, product)

	// Update atom temperature.
	if(abs(air.temperature - last_air_temperature) >= ATOM_TEMPERATURE_EQUILIBRIUM_THRESHOLD)
		last_air_temperature = air.temperature
		for(var/turf/simulated/T in contents)
			for(var/check_atom in T.contents)
				var/atom/checking = check_atom
				if(checking.simulated)
					QUEUE_TEMPERATURE_ATOMS(checking)
			CHECK_TICK

/zone/proc/dbg_data(mob/M)
	to_chat(M, name)
	for(var/g in air.gas)
		to_chat(M, "[gas_data.name[g]]: [air.gas[g]]")
	to_chat(M, "P: [air.return_pressure()] kPa V: [air.volume]L T: [air.temperature]°K ([air.temperature - T0C]°C)")
	to_chat(M, "O2 per N2: [(air.gas[GAS_NITROGEN] ? air.gas[GAS_OXYGEN]/air.gas[GAS_NITROGEN] : "N/A")] Moles: [air.total_moles]")
	to_chat(M, "Simulated: [length(contents)] ([air.group_multiplier])")
//	to_chat(M, "Unsimulated: [length(unsimulated_contents)]")
//	to_chat(M, "Edges: [length(edges)]")
	if(invalid) to_chat(M, "Invalid!")
	var/zone_edges = 0
	var/space_edges = 0
	var/space_coefficient = 0
	for(var/connection_edge/E in edges)
		if(E.type == /connection_edge/zone) zone_edges++
		else
			space_edges++
			space_coefficient += E.coefficient
			to_chat(M, "[E:air:return_pressure()]kPa")

	to_chat(M, "Zone Edges: [zone_edges]")
	to_chat(M, "Space Edges: [space_edges] ([space_coefficient] connections)")

	//for(var/turf/T in unsimulated_contents)
//		to_chat(M, "[T] at ([T.x],[T.y])")
