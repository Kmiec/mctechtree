module Processing
  def is_process_template? process
    process.include? 'vars'
  end

  def load_processing definitions, group=nil
    definitions.each do |process|
      if is_process_template? process
        transform_template(process).each do |p| 
          # processes don't have a name, so they expand to {nil => {inputs=>...,outputs=>}}
          load_single_process p.values.first, group
        end
      else
        load_single_process process, group
      end
    end
  end

  def load_single_process process, group
    inputs = process.delete('inputs')
    outputs = process.delete('outputs')
    if outputs.size == 1
      load_single_craft craft_process(inputs, outputs.first, process), group
    else
      skip = (process.delete('skip-output') || @defaults['skip-output']).to_a
      outputs.each do |name|
        next if skip.include? name
        load_single_craft craft_process(inputs, name, process.dup), group
      end
    end
  end

  def craft_process inputs, output, extra
     if output =~ /(.+?)\*(\d+)/
       name, makes = $1, $2.to_i
     else
       name, makes = output, 1
     end
     machine = extra.delete('machine') || @defaults['machine']
     # NOTE: code duplication with parse_recipe
     shape_map, ingredients = strip_shapes(inputs)
     ingredients = resolve_items(ingredients)
     shape_map = resolve_shapes(shape_map, ingredients)
     extra['shape_map'] = shape_map unless shape_map.empty?
     [name, makes, machine, ingredients, extra]
  end
end
