defmodule LemonSim.Examples.Skirmish.MapGenerator do
  @moduledoc false

  @default_width 10
  @default_height 10
  @default_cover_density 0.15
  @default_wall_density 0.08
  @default_water_density 0.05
  @high_ground_min 2
  @high_ground_max 4

  @spec generate(keyword()) :: map()
  def generate(opts \\ []) do
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))
    cover_density = Keyword.get(opts, :cover_density, @default_cover_density)
    wall_density = Keyword.get(opts, :wall_density, @default_wall_density)
    water_density = Keyword.get(opts, :water_density, @default_water_density)

    state = :rand.seed_s(:exsss, seed)

    {walls, state} = generate_walls(width, height, wall_density, state)
    occupied = MapSet.new(walls, fn pos -> {pos.x, pos.y} end)

    {water, state} = generate_water(width, height, water_density, occupied, state)
    occupied = Enum.reduce(water, occupied, fn pos, acc -> MapSet.put(acc, {pos.x, pos.y}) end)

    {cover, state} = generate_cover(width, height, cover_density, occupied, state)
    occupied = Enum.reduce(cover, occupied, fn pos, acc -> MapSet.put(acc, {pos.x, pos.y}) end)

    {high_ground, _state} = generate_high_ground(width, height, occupied, state)

    %{
      width: width,
      height: height,
      cover: cover,
      walls: walls,
      water: water,
      high_ground: high_ground
    }
  end

  @spec spawn_positions(map(), :red | :blue, pos_integer()) :: [map()]
  def spawn_positions(map, team, count) do
    occupied = all_occupied(map)
    columns = spawn_columns(map.width, team)

    columns
    |> Enum.flat_map(fn x ->
      Enum.map(0..(map.height - 1), fn y -> %{x: x, y: y} end)
    end)
    |> Enum.reject(fn pos -> MapSet.member?(occupied, {pos.x, pos.y}) end)
    |> Enum.take(count)
  end

  @spec preset_maps() :: %{arena: map(), fortress: map(), wetlands: map(), alley: map(), crossroads: map()}
  def preset_maps do
    %{
      arena: preset_arena(),
      fortress: preset_fortress(),
      wetlands: preset_wetlands(),
      alley: preset_alley(),
      crossroads: preset_crossroads()
    }
  end

  # -- Walls: small clusters (1-3 tiles) for choke points --

  defp generate_walls(width, height, density, state) do
    target_count = max(1, round(width * height * density))
    generate_wall_clusters(width, height, target_count, [], MapSet.new(), state)
  end

  defp generate_wall_clusters(_width, _height, remaining, walls, _occupied, state)
       when remaining <= 0 do
    {walls, state}
  end

  defp generate_wall_clusters(width, height, remaining, walls, occupied, state) do
    {x, state} = rand_int(state, 0, width - 1)
    {y, state} = rand_int(state, 0, height - 1)
    {cluster_size, state} = rand_int(state, 1, min(3, remaining))

    if in_spawn_zone?(x, width) or MapSet.member?(occupied, {x, y}) do
      generate_wall_clusters(width, height, remaining, walls, occupied, state)
    else
      {cluster, occupied, state} =
        grow_cluster(x, y, cluster_size, width, height, occupied, state)

      generate_wall_clusters(
        width,
        height,
        remaining - length(cluster),
        walls ++ cluster,
        occupied,
        state
      )
    end
  end

  defp grow_cluster(x, y, size, width, height, occupied, state) do
    seed_pos = %{x: x, y: y}
    occupied = MapSet.put(occupied, {x, y})
    grow_cluster_from([seed_pos], size - 1, width, height, occupied, state)
  end

  defp grow_cluster_from(cluster, 0, _width, _height, occupied, state) do
    {cluster, occupied, state}
  end

  defp grow_cluster_from(cluster, remaining, width, height, occupied, state) do
    last = List.last(cluster)
    neighbors = adjacent_tiles(last.x, last.y, width, height)

    valid =
      Enum.reject(neighbors, fn {nx, ny} ->
        MapSet.member?(occupied, {nx, ny}) or in_spawn_zone?(nx, width)
      end)

    case valid do
      [] ->
        {cluster, occupied, state}

      candidates ->
        {idx, state} = rand_int(state, 0, length(candidates) - 1)
        {nx, ny} = Enum.at(candidates, idx)
        pos = %{x: nx, y: ny}
        occupied = MapSet.put(occupied, {nx, ny})
        grow_cluster_from(cluster ++ [pos], remaining - 1, width, height, occupied, state)
    end
  end

  # -- Water: small rivers (2-4 connected tiles in a line) --

  defp generate_water(width, height, density, occupied, state) do
    target_count = max(1, round(width * height * density))
    generate_water_rivers(width, height, target_count, [], occupied, state)
  end

  defp generate_water_rivers(_width, _height, remaining, water, _occupied, state)
       when remaining <= 0 do
    {water, state}
  end

  defp generate_water_rivers(width, height, remaining, water, occupied, state) do
    {x, state} = rand_int(state, 0, width - 1)
    {y, state} = rand_int(state, 0, height - 1)
    {river_len, state} = rand_int(state, 2, min(4, remaining))
    {direction, state} = rand_direction(state)

    if in_spawn_zone?(x, width) or MapSet.member?(occupied, {x, y}) do
      generate_water_rivers(width, height, remaining, water, occupied, state)
    else
      {river, occupied} =
        build_river(x, y, direction, river_len, width, height, occupied)

      generate_water_rivers(
        width,
        height,
        remaining - length(river),
        water ++ river,
        occupied,
        state
      )
    end
  end

  defp build_river(x, y, {dx, dy}, length, width, height, occupied) do
    build_river_tiles(x, y, dx, dy, length, width, height, occupied, [])
  end

  defp build_river_tiles(_x, _y, _dx, _dy, 0, _width, _height, occupied, tiles) do
    {tiles, occupied}
  end

  defp build_river_tiles(x, y, dx, dy, remaining, width, height, occupied, tiles) do
    if x < 0 or x >= width or y < 0 or y >= height or
         in_spawn_zone?(x, width) or MapSet.member?(occupied, {x, y}) do
      {tiles, occupied}
    else
      pos = %{x: x, y: y}
      occupied = MapSet.put(occupied, {x, y})

      build_river_tiles(
        x + dx,
        y + dy,
        dx,
        dy,
        remaining - 1,
        width,
        height,
        occupied,
        tiles ++ [pos]
      )
    end
  end

  # -- Cover: scattered with some clustering --

  defp generate_cover(width, height, density, occupied, state) do
    target_count = max(1, round(width * height * density))
    generate_cover_tiles(width, height, target_count, [], occupied, state)
  end

  defp generate_cover_tiles(_width, _height, remaining, cover, _occupied, state)
       when remaining <= 0 do
    {cover, state}
  end

  defp generate_cover_tiles(width, height, remaining, cover, occupied, state) do
    {x, state} = rand_int(state, 0, width - 1)
    {y, state} = rand_int(state, 0, height - 1)
    {cluster?, state} = rand_float(state)

    if in_spawn_zone?(x, width) or MapSet.member?(occupied, {x, y}) do
      generate_cover_tiles(width, height, remaining, cover, occupied, state)
    else
      pos = %{x: x, y: y}
      occupied = MapSet.put(occupied, {x, y})

      # 40% chance to place one adjacent cover tile for clustering
      if cluster? < 0.4 and remaining > 1 do
        neighbors = adjacent_tiles(x, y, width, height)

        valid =
          Enum.reject(neighbors, fn {nx, ny} ->
            MapSet.member?(occupied, {nx, ny}) or in_spawn_zone?(nx, width)
          end)

        case valid do
          [] ->
            generate_cover_tiles(
              width,
              height,
              remaining - 1,
              cover ++ [pos],
              occupied,
              state
            )

          candidates ->
            {idx, state} = rand_int(state, 0, length(candidates) - 1)
            {nx, ny} = Enum.at(candidates, idx)
            neighbor_pos = %{x: nx, y: ny}
            occupied = MapSet.put(occupied, {nx, ny})

            generate_cover_tiles(
              width,
              height,
              remaining - 2,
              cover ++ [pos, neighbor_pos],
              occupied,
              state
            )
        end
      else
        generate_cover_tiles(
          width,
          height,
          remaining - 1,
          cover ++ [pos],
          occupied,
          state
        )
      end
    end
  end

  # -- High ground: rare, 2-4 tiles per map --

  defp generate_high_ground(width, height, occupied, state) do
    {count, state} = rand_int(state, @high_ground_min, @high_ground_max)
    generate_high_ground_tiles(width, height, count, [], occupied, state)
  end

  defp generate_high_ground_tiles(_width, _height, 0, tiles, _occupied, state) do
    {tiles, state}
  end

  defp generate_high_ground_tiles(width, height, remaining, tiles, occupied, state) do
    {x, state} = rand_int(state, 0, width - 1)
    {y, state} = rand_int(state, 0, height - 1)

    if in_spawn_zone?(x, width) or MapSet.member?(occupied, {x, y}) do
      generate_high_ground_tiles(width, height, remaining, tiles, occupied, state)
    else
      pos = %{x: x, y: y}
      occupied = MapSet.put(occupied, {x, y})
      generate_high_ground_tiles(width, height, remaining - 1, tiles ++ [pos], occupied, state)
    end
  end

  # -- Preset maps --

  defp preset_arena do
    %{
      width: 10,
      height: 10,
      cover: [
        %{x: 3, y: 2},
        %{x: 3, y: 7},
        %{x: 5, y: 4},
        %{x: 5, y: 5},
        %{x: 6, y: 2},
        %{x: 6, y: 7},
        %{x: 4, y: 4},
        %{x: 4, y: 5}
      ],
      walls: [
        %{x: 5, y: 0},
        %{x: 5, y: 9}
      ],
      water: [],
      high_ground: [
        %{x: 4, y: 0},
        %{x: 4, y: 9}
      ]
    }
  end

  defp preset_fortress do
    %{
      width: 10,
      height: 10,
      cover: [
        %{x: 2, y: 4},
        %{x: 2, y: 5},
        %{x: 7, y: 4},
        %{x: 7, y: 5}
      ],
      walls: [
        %{x: 3, y: 2},
        %{x: 3, y: 3},
        %{x: 3, y: 6},
        %{x: 3, y: 7},
        %{x: 4, y: 4},
        %{x: 4, y: 5},
        %{x: 5, y: 4},
        %{x: 5, y: 5},
        %{x: 6, y: 2},
        %{x: 6, y: 3},
        %{x: 6, y: 6},
        %{x: 6, y: 7}
      ],
      water: [],
      high_ground: [
        %{x: 4, y: 0},
        %{x: 5, y: 9}
      ]
    }
  end

  defp preset_wetlands do
    %{
      width: 10,
      height: 10,
      cover: [
        %{x: 3, y: 1},
        %{x: 5, y: 3},
        %{x: 4, y: 6},
        %{x: 6, y: 8},
        %{x: 7, y: 2}
      ],
      walls: [
        %{x: 5, y: 5}
      ],
      water: [
        %{x: 3, y: 3},
        %{x: 3, y: 4},
        %{x: 3, y: 5},
        %{x: 4, y: 4},
        %{x: 5, y: 6},
        %{x: 5, y: 7},
        %{x: 5, y: 8},
        %{x: 6, y: 3},
        %{x: 6, y: 4},
        %{x: 6, y: 5},
        %{x: 7, y: 5},
        %{x: 7, y: 6}
      ],
      high_ground: [
        %{x: 4, y: 1},
        %{x: 6, y: 9}
      ]
    }
  end

  defp preset_alley do
    %{
      width: 8,
      height: 4,
      cover: [
        %{x: 3, y: 1},
        %{x: 3, y: 2},
        %{x: 4, y: 1},
        %{x: 4, y: 2}
      ],
      walls:
        Enum.map(1..6, fn x -> %{x: x, y: 0} end) ++
          Enum.map(1..6, fn x -> %{x: x, y: 3} end),
      water: [],
      high_ground: []
    }
  end

  defp preset_crossroads do
    %{
      width: 6,
      height: 6,
      cover: [
        %{x: 1, y: 1},
        %{x: 1, y: 4},
        %{x: 4, y: 1},
        %{x: 4, y: 4}
      ],
      walls: [],
      water: [],
      high_ground: [
        %{x: 2, y: 2},
        %{x: 3, y: 3}
      ]
    }
  end

  # -- Helpers --

  defp in_spawn_zone?(x, width) do
    x == 0 or x == width - 1
  end

  defp spawn_columns(_width, :red), do: [0]
  defp spawn_columns(width, :blue), do: [width - 1]

  defp adjacent_tiles(x, y, width, height) do
    [{x - 1, y}, {x + 1, y}, {x, y - 1}, {x, y + 1}]
    |> Enum.filter(fn {nx, ny} ->
      nx >= 0 and nx < width and ny >= 0 and ny < height
    end)
  end

  defp all_occupied(map) do
    (map.cover ++ map.walls ++ map.water ++ Map.get(map, :high_ground, []))
    |> MapSet.new(fn pos -> {pos.x, pos.y} end)
  end

  defp rand_int(state, min, max) when min >= max, do: {min, state}

  defp rand_int(state, min, max) do
    {value, state} = :rand.uniform_s(max - min + 1, state)
    {value - 1 + min, state}
  end

  defp rand_float(state) do
    :rand.uniform_s(state)
  end

  defp rand_direction(state) do
    directions = [{1, 0}, {0, 1}, {-1, 0}, {0, -1}]
    {idx, state} = rand_int(state, 0, 3)
    {Enum.at(directions, idx), state}
  end
end
