require 'fourflusher'
require 'xcpretty'

CONFIGURATION = "Release"
PLATFORMS = { 
  'iphonesimulator' => 'iOS',
  'appletvsimulator' => 'tvOS',
  'watchsimulator' => 'watchOS' 
}

#  Build specific target to framework file
#  @param [PodTarget] target
#         a specific pod target
#
def build_for_iosish_platform(
  sandbox, 
  build_dir, 
  output_path,
  target, 
  device, 
  simulator,
  bitcode_enabled,
  build_xcframework,
  custom_build_options = [], # Array<String>
  custom_build_options_simulator = [] # Array<String>
)

  deployment_target = target.platform.deployment_target.to_s
  target_label = target.label # name with platform if it's used in multiple platforms

  if build_xcframework

    Pod::UI.puts "Prebuilding #{target_label}... as XCFramework, bitcode: #{bitcode_enabled ? "YES" : "NO"}"  
    other_options = []
    # bitcode enabled
    if bitcode_enabled
      other_options += ['ENABLE_BITCODE=YES']
      other_options += ["BITCODE_GENERATION_MODE=bitcode"]
      other_options += ["OTHER_CFLAGS=-fembed-bitcode"]
    end
  
    other_options += ['BUILD_LIBRARY_FOR_DISTRIBUTION=true']

    other_options += ['SKIP_INSTALL=NO']

    xcodebuild(
      sandbox: sandbox,
      scheme: target_label,
      sdk: device,
      deployment_target: deployment_target,
      other_options: other_options + custom_build_options
    )

    xcodebuild(
      sandbox: sandbox,
      scheme: target_label,
      sdk: simulator,
      deployment_target: deployment_target,
      other_options: other_options + custom_build_options_simulator
    )

    # paths
    target_name = target.name # equals target.label, like "AFNeworking-iOS" when AFNetworking is used in multiple platforms.
    module_name = target.product_module_name

    device_lib = "#{build_dir}/#{CONFIGURATION}-#{device}/#{target_name}/#{module_name}.framework"
    simulator_lib = "#{build_dir}/#{CONFIGURATION}-#{simulator}/#{target_name}/#{module_name}.framework"

    create_xcframework([device_lib, simulator_lib], output_path, module_name)    
    # copy_dsym_files(sandbox_root.parent + 'dSYM', CONFIGURATION)

    dSYM_path = output_path + "#{module_name}.dSYMs"

    dSYM_path.mkpath unless dSYM_path.exist?
    FileUtils.mv device_lib + ".dSYM", File.join(dSYM_path, "#{device}.dSYM")
    FileUtils.mv simulator_lib + ".dSYM", File.join(dSYM_path, "#{simulator}.dSYM")

  else

    Pod::UI.puts "Prebuilding #{target_label}... as Universal Framework"

    # https://steipete.com/posts/couldnt-irgen-expression/
    other_options = [
      "SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO"
    ]

    if bitcode_enabled
      other_options += ["ENABLE_BITCODE=YES"]
      other_options += ["BITCODE_GENERATION_MODE=bitcode"]
      other_options += ["OTHER_CFLAGS=-fembed-bitcode"]
    end

    xcodebuild(
      sandbox: sandbox,
      scheme: target_label,
      sdk: device,
      deployment_target: deployment_target,
      other_options: other_options + custom_build_options
    )

    # make less arch to iphone simulator for faster build
    other_options += ["ARCHS=x86_64", "ONLY_ACTIVE_ARCH=NO"] if simulator == "iphonesimulator"

    xcodebuild(
      sandbox: sandbox,
      scheme: target_label,
      sdk: simulator,
      deployment_target: deployment_target,
      other_options: other_options + custom_build_options_simulator
    )

    # paths
    target_name = target.name # equals target.label, like "AFNeworking-iOS" when AFNetworking is used in multiple platforms.
    module_name = target.product_module_name

    device_lib = "#{build_dir}/#{CONFIGURATION}-#{device}/#{target_name}/#{module_name}.framework"
    simulator_lib = "#{build_dir}/#{CONFIGURATION}-#{simulator}/#{target_name}/#{module_name}.framework"

    create_universal_framework(
      device_lib, 
      simulator_lib,
      build_dir,
      target_name,
      module_name,
      output_path
    )
    
  end
  
end

def build_for_macos_platform(sandbox, build_dir, target, flags, configuration, build_xcframework=false)
  target_label = target.cocoapods_target_label
  xcodebuild(sandbox, target_label, flags, configuration)

  spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
  spec_names.each do |root_name, module_name|
    if build_xcframework
      framework = "#{build_dir}/#{configuration}/#{root_name}/#{module_name}.framework"
      build_xcframework([framework], build_dir, module_name)
    end
  end
end

def enable_debug_information(project_path, configuration)
  project = Xcodeproj::Project.open(project_path)
  project.targets.each do |target|
    config = target.build_configurations.find { |config| config.name.eql? configuration }
    config.build_settings["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
    config.build_settings["ONLY_ACTIVE_ARCH"] = "NO"
  end
  project.save
end

def create_xcframework(frameworks, destination, module_name)
  args = %W(-create-xcframework -output #{destination}/#{module_name}.xcframework)

  frameworks.each do |framework|
    args += %W(-framework #{framework})
  end

  Pod::Executable.execute_command 'xcodebuild', args, true
end

def create_universal_framework(device_lib, simulator_lib, build_dir, target_name, module_name, output_path)

  device_binary = device_lib + "/#{module_name}"
  simulator_binary = simulator_lib + "/#{module_name}"

  Pod::UI.puts "#{device_binary} #{simulator_binary}"

  unless File.file?(device_binary) && File.file?(simulator_binary)
    Pod::UI.puts "Binary not found"
    return
  end

  # the device_lib path is the final output file path
  # combine the binaries
  tmp_lipoed_binary_path = "#{build_dir}/#{target_name}"
  lipo_log = `lipo -create -output #{tmp_lipoed_binary_path} #{device_binary} #{simulator_binary}`
  puts lipo_log unless File.exist?(tmp_lipoed_binary_path)
  FileUtils.mv tmp_lipoed_binary_path, device_binary, :force => true
  
  # collect the swiftmodule file for various archs.
  device_swiftmodule_path = device_lib + "/Modules/#{module_name}.swiftmodule"
  simulator_swiftmodule_path = simulator_lib + "/Modules/#{module_name}.swiftmodule"
  if File.exist?(device_swiftmodule_path)
    FileUtils.cp_r simulator_swiftmodule_path + "/.", device_swiftmodule_path
  end

  # combine the generated swift headers
  # (In xcode 10.2, the generated swift headers vary for each archs)
  # https://github.com/leavez/cocoapods-binary/issues/58
  simulator_generated_swift_header_path = simulator_lib + "/Headers/#{module_name}-Swift.h"
  device_generated_swift_header_path = device_lib + "/Headers/#{module_name}-Swift.h"
  if File.exist? simulator_generated_swift_header_path
    device_header = File.read(device_generated_swift_header_path)
    simulator_header = File.read(simulator_generated_swift_header_path)
    # https://github.com/Carthage/Carthage/issues/2718#issuecomment-473870461
    combined_header_content = %Q{
#if TARGET_OS_SIMULATOR // merged by cocoapods-binary

#{simulator_header}

#else // merged by cocoapods-binary

#{device_header}

#endif // merged by cocoapods-binary
}
    File.write(device_generated_swift_header_path, combined_header_content.strip)
  end

  # handle the dSYM files
  device_dsym = "#{device_lib}.dSYM"
  if File.exist? device_dsym
    # lipo the simulator dsym
    simulator_dsym = "#{simulator_lib}.dSYM"
    if File.exist? simulator_dsym
      tmp_lipoed_binary_path = "#{output_path}/#{module_name}.draft"
      lipo_log = `lipo -create -output #{tmp_lipoed_binary_path} #{device_dsym}/Contents/Resources/DWARF/#{module_name} #{simulator_dsym}/Contents/Resources/DWARF/#{module_name}`
      puts lipo_log unless File.exist?(tmp_lipoed_binary_path)
      FileUtils.mv tmp_lipoed_binary_path, "#{device_lib}.dSYM/Contents/Resources/DWARF/#{module_name}", :force => true
    end
    # move
    FileUtils.mv device_dsym, output_path, :force => true
  end

  # output
  output_path.mkpath unless output_path.exist?
  FileUtils.mv device_lib, output_path, :force => true

end

def xcodebuild(
  sandbox:, 
  scheme:, 
  sdk:,
  deployment_target:,
  other_options:
  )

  args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{scheme} -configuration #{CONFIGURATION} -sdk #{sdk} )
  platform = PLATFORMS[sdk]
  args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?
  args += other_options
  log = `xcodebuild #{args.join(" ")} 2>&1`
  exit_code = $?.exitstatus  # Process::Status
  is_succeed = (exit_code == 0)

  if !is_succeed
    begin
        if log.include?('** BUILD FAILED **')
            # use xcpretty to print build log
            # 64 represent command invalid. http://www.manpagez.com/man/3/sysexits/
            printer = XCPretty::Printer.new({:formatter => XCPretty::Simple, :colorize => 'auto'})
            log.each_line do |line|
              printer.pretty_print(line)
            end
        else
            raise "shouldn't be handle by xcpretty"
        end
    rescue
        puts log.red
    end
  end
  [is_succeed, log]

end

module Pod
   class Prebuild

    # Build the frameworks with sandbox and targets
    #
    # @param  [String] sandbox_root_path
    #         The sandbox root path where the targets project place
    #         
    #         [PodTarget] target
    #         The pod targets to build
    #
    #         [Pathname] output_path
    #         output path for generated frameworks
    #
    def self.build(sandbox_root_path, target, output_path, bitcode_enabled, custom_build_options=[], custom_build_options_simulator=[])
    
      return if target.nil?
    
      sandbox_root = Pathname(sandbox_root_path)
      sandbox = Pod::Sandbox.new(sandbox_root)
      build_dir = self.build_dir(sandbox_root)

      enable_debug_information(sandbox.project_path, CONFIGURATION)

      # -- build the framework
      case target.platform.name
      when :ios then 
        build_for_iosish_platform(
          sandbox,
          build_dir,
          output_path, 
          target, 
          'iphoneos', 
          'iphonesimulator', 
          bitcode_enabled, 
          false,
          custom_build_options, 
          custom_build_options_simulator
        )
      when :osx then
        xcodebuild(
          sandbox, 
          target.label, 
          'macosx', 
          nil, 
          custom_build_options
        )
      # when :tvos then build_for_iosish_platform(sandbox, build_dir, target, 'appletvos', 'appletvsimulator')
      when :watchos then
        build_for_iosish_platform(
          sandbox, 
          build_dir, 
          output_path, 
          target, 
          'watchos', 
          'watchsimulator', 
          true, 
          false,
          custom_build_options, 
          custom_build_options_simulator
        )
      else raise "Unsupported platform for '#{target.name}': '#{target.platform.name}'" end
    
      raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

    end

    def self.build_xcframework(sandbox_root_path, target, output_path, bitcode_enabled, custom_build_options=[], custom_build_options_simulator=[])

      Pod::UI.puts "Build XCFramework"
    
      return if target.nil?
    
      sandbox_root = Pathname(sandbox_root_path)
      sandbox = Pod::Sandbox.new(sandbox_root)
      build_dir = self.build_dir(sandbox_root)

      # -- build the framework
      case target.platform.name
      when :ios then 
        build_for_iosish_platform(
          sandbox, 
          build_dir, 
          output_path,
          target, 
          'iphoneos', 
          'iphonesimulator', 
          bitcode_enabled, 
          true,
          custom_build_options, 
          custom_build_options_simulator
        )
      when :osx then 
        xcodebuild(
          sandbox, 
          target.label, 
          'macosx', 
          nil, 
          custom_build_options
        )
      # when :tvos then build_for_iosish_platform(sandbox, build_dir, target, 'appletvos', 'appletvsimulator')
      when :watchos then 
        build_for_iosish_platform(
          sandbox, 
          build_dir, 
          output_path, 
          target, 
          'watchos', 
          'watchsimulator',
          true,           
          true,
          custom_build_options, 
          custom_build_options_simulator
        )
      else raise "Unsupported platform for '#{target.name}': '#{target.platform.name}'" end
    
      raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

    end
    
    def self.remove_build_dir(sandbox_root)
      path = build_dir(sandbox_root)
      path.rmtree if path.exist?
    end

    private 
    
    def self.build_dir(sandbox_root)
      # don't know why xcode chose this folder
      sandbox_root.parent + 'build' 
    end

  end
end
