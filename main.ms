// Pulls in api key and organization from secrets.yml
_config("ChatGPT",
    associative_array(
        "openai_api_key": "insertkeyhere",
        "openai_organization": "insertorgcodehere"
    ),
    "secrets.yml"
);

_config("ChatGPT",
    associative_array(
        "NPCs":associative_array(
            "Mistral":associative_array(
                "description":  "a friendly and cheerful girl who lives at Angel Peak and tends the gardens. She is very forgiving and likely to let her relationship score increase more easily than decrease with players.",
                "personality":  "Friendly and charismatic",
                "tone":         "Positive",
                "relationships": associative_array(
                    "Rufus":    "Dear friend, mentor, and father figure",
                    "Rolph":    "Friend and business partner",
                    "Postman":  "Acquaintance",
                    "Warden":   "Never met",
                    "Luna":  "Curious about her magical abilities",
                    "Gideon":  "Admires his swordsmanship"
                )
            )
        )
    )
);

// Conversations is a list of transcripts of conversations between players and NPCs
_load("ChatGPT.Messages",array());
_load("ChatGPT.History","");
_load("ChatGPT.Cooldowns");

// Profiles is a 2D associative array of player UUIDs and their NPC relationship scores
_load("ChatGPT.Profiles");

// These three procs are just for convenience, they produce message objects for ChatGPTs input
proc _system(@message){

    return(associative_array(
        "role":"system",
        "content":@message
    ));
}

proc _user(@message,@npc,@player){
    @time = time();
    return(associative_array(
        "role":"user",
        "content":"@player to @npc at @time: @message"
    ));
}

proc _assistant(@message,@npc,@player){
    @time = time();
    return(associative_array(
        "role":"assistant",
        "content":"@npc to @player at @time: @message"
    ));
}

// This proc compiles data including NPC descriptions, personalities, and relationship scores, player name and rank, and weather and time of day, and the ChatGPT system instructions into a JSON object and sends it to OpenAI's API. It then handles the response, and broadcasts it to the server.
proc _message_gpt(@puuid,@input,@npc,@private,@type,@iterate){
    x_new_thread("ChatGPT",closure(){
        if(@iterate === ""){ @iterate = 0; }
        @history = import("ChatGPT.History");
        @npcs = import("AR.Config.ChatGPT")["NPCs"];
        @dashless = replace(@puuid,"-",""); // This is uneccessary, but in certain other instances dashes cause a problem, so I'm just being safe.

        // This collection of data into variables is to allow smartstrings to use the values without needing to concatenate a bunch of stuff later on.
        @npc_description = @npcs[@npc]["description"];
        @npc_personality = @npcs[@npc]["personality"];
        @npc_tone = @npcs[@npc]["tone"];
        @npc_relationships = @npcs[@npc]["relationships"];
        @npc_displayname = @npcs[@npc]["displayname"];
        @game_day = get_world_day('world');
        if(has_storm('world')){
            if(has_thunder('world')){
                @weather = "Thunderstorm"
            }else{
                @weather = "Raining"
            }
        }else{
            @weather = "Clear"
        }
        @time_of_day = get_world_time('world');

        @player = player(@puuid);
        @cooldowns = import("ChatGPT.Cooldowns");
        @cooldown_key = @player."-".@npc;
        @cooldowns[@cooldown_key] = time() + 60 * 1000;

        //This is a bit of a mess, but it's just to get the player's rank and rank description. There may be a proc somewhere in another file to get the top rank.
        @pgroups = vault_pgroup(@player);

        if(@player == "VergilPrime"){
            @rank = "owner";
            @rank_description = "the owner and head admin of";
        }else if(array_contains_ic(@pgroups,"admin")){
            @rank = "admin";
            @rank_description = "an admin, the highest staff rank on";
        }else if(array_contains_ic(@pgroups,"supermod")){
            @rank = "supermod";
            @rank_description = "a supermod, the second highest staff rank on";
        }else if(array_contains_ic(@pgroups,"moderator")){
            @rank = "moderator";
            @rank_description = "a moderator, the lowest staff rank on";
        }else if(array_contains_ic(@pgroups,"trusted")){
            @rank = "trusted";
            @rank_description = "a trusted player on";
        }else if(array_contains_ic(@pgroups,"player")){
            @rank = "player";
            @rank_description = "a normal player on";
        }else if(array_contains_ic(@pgroups,"guest")){
            @rank = "guest";
            @rank_description = "a new, unranked player on";
        }

        // There should be no problem updating to GPT-4 if and when I get a beta key. This will increase the token limit!
        @model = "gpt-3.5-turbo-0613";
        // I was informed that the maximum value for this was 2, but now Github Copilot is telling me that it's 1. That's probably why it was giving me unhinged results before.
        @crazy = 1; // Keep under 1!
        @endpoint = "https://api.openai.com/v1/chat/completions";
        @apikey = import("AR.Config.ChatGPT.secrets")["openai_api_key"];
        @organization = import("AR.Config.ChatGPT.secrets")["openai_organization"];
        @headers = associative_array(
            "Content-Type": "application/json",
            "Authorization": "Bearer @apikey",
            "OpenAI-Organization": @organization
        );

        //TODO: I plan on having a server-wide NPC here with no relationship score who just monitors chat and helps players with commands and stuff. This is just a placeholder for now.
        
        // If the player has a relationship score with the NPC, use that. Otherwise, use 50 as the neutral score.

        // This is the schema for the function call to the ChatGPT API.

        @schema_query = associative_array(
            "type": "object",
            "properties": associative_array(
                "data": associative_array("type": "string",
                    "description": "The data needed to continue the conversation. Can be one of: <lore_info, server_info, player_info>"),
                "player": associative_array("type": "string",
                    "description": "The player's name or UUID you want information about. Only used when data is player_info")
            ),
            "required": array("data")
        );

        @functions = array(
            associative_array("name": "query", "parameters":@schema_query, "description":"Get more data about the server, the player, or the lore before replying to the player")
        );

        //TODO: This is the system prompt. I'm open to suggestions on how to improve and optimize it.
        @system_prompt = read("system_prompt.txt");
        @system_prompt = replace(@system_prompt,"{npc}",@npc);
        @system_prompt = replace(@system_prompt,"{npc_description}",@npc_description);
        @system_prompt = replace(@system_prompt,"{npc_tone}",@npc_tone);
        @system_prompt = replace(@system_prompt,"{npc_personality}",@npc_personality);
        @system_prompt = replace(@system_prompt,"{npc_relationships}",@npc_relationships);
        @system_prompt = replace(@system_prompt,"{player}",@player);
        @system_prompt = replace(@system_prompt,"{rank_description}",@rank_description);
        @system_prompt = replace(@system_prompt,"{rank}",@rank);

        // Here we build the messages array by pushing the system text, then each conversation in the conversation array, then the user's input.
        @messages = import("ChatGPT.Messages")[];
        array_insert(@messages,_system(@system_prompt),0);

        foreach(@index:@message in @messages){
            if(@message["role"] === "user"){
                @msg_array = split(" ",@message["content"]);
                @msg_player = @msg_array[0]
                @msg_npc = @msg_array[2]
                @timestamp = integer(replace(@msg_array[4],":",""));
            }else if(@message["role"] === "assistant"){
                @msg_array = split(" ",@message["content"]);
                @msg_npc = @msg_array[0]
                @msg_player = @msg_array[2]
                @timestamp = integer(replace(@msg_array[4],":",""));
            }
            if(@message["role"] !== "system" && (@msg_player !== @player || @msg_npc !== @npc) && @timestamp < time() - (60 * 60 * 1000)){
                array_remove(@messages,@index);
                continue(0);
            }
        }

        @silent = true;
        switch(@type){
            case "conversation":
                @silent = false;

                if(@input !== ""){
                    array_push(@messages,_user(@input,@npc,@player));
                    array_push(import("ChatGPT.Messages"),_user(@input,@npc,@player));
                    _save("ChatGPT.Messages");
                }
                if(@private){
                    msg(color(7).@player.": ".@input);
                }else{
                    broadcast(color(7).@player.": ".@input);
                }
            case "lore_info":
                array_push(@messages,_system("lore.txt"));
            case "server_info":
                array_push(@messages,_system(yml_encode(associative_array(
                    "address":"Angels-Reach.com",
                    "website":"https://www.angels-reach.com",
                    "map":"https://map.angels-reach.com:8100",
                    "discord":"https://discord.gg/NtfznDcu8E",
                    "plugins":get_server_info(9)
                ),true)));
            case "player_info":
                @query_player = _uuidreg_get_closest_name(@input);

                if(is_null(@query_player)){
                    array_push(@messages,"That player wasn't recognized.");
                }

                @qdashless = _uuidreg_get_uuid(@query_player);
                
                @qpgroups = vault_pgroup(@query_player);
                if(array_contains_ic(@qpgroups,"neutral")){
                    @karma_title = "neutral";
                    @karma_title_description = "a neutral player";
                }else if(array_contains_ic(@qpgroups,"brave")){
                    @karma_title = "brave";
                    @karma_title_description = "a burgeoning hero";
                }else if(array_contains_ic(@qpgroups,"cruel")){
                    @karma_title = "cruel";
                    @karma_title_description = "a player starting down a dark path"
                }else if(array_contains_ic(@qpgroups,"hero")){
                    @karma_title = "hero";
                    @karma_title_description = "a proven hero of Angel's Reach";
                }else if(array_contains_ic(@qpgroups,"terrible")){
                    @karma_title = "terrible";
                    @karma_title_description = "a nightmare, to be avoided";
                }else if(array_contains_ic(@qpgroups,"savior")){
                    @karma_title = "savior";
                    @karma_title_description = "an actual saint and protector of the weak";
                }else if(array_contains_ic(@qpgroups,"destroyer")){
                    @karma_title = "destroyer";
                    @karma_title_description = "a force of destruction and chaos";
                }else if(array_contains_ic(@qpgroups,"archangel")){
                    @karma_title = "archangel";
                    @karma_title_description = "the ultimate foil of evil";
                }else if(array_contains_ic(@qpgroups,"herobrine")){
                    @karma_title = "herobrine";
                    @karma_title_description = "the darkness seeping through the world";
                }else{
                    @karma_title = "neutral";
                    @karma_title_description = "a neutral player";
                }
                
                if(array_contains_ic(@qpgroups,"civilian")){
                    @combat_title = "civilian";
                    @combat_title_description = "a civilian, with little combat experience";
                }else if(array_contains_ic(@qpgroups,"defender")){
                    @combat_title = "defender";
                    @combat_title_description = "a person who knows how to defend themselves";
                }else if(array_contains_ic(@qpgroups,"soldier")){
                    @combat_title = "soldier";
                    @combat_title_description = "a fighter who has tasted battle";
                }else if(array_contains_ic(@qpgroups,"aggressor")){
                    @combat_title = "aggressor";
                    @combat_title_description = "a person who seeks out fights";
                }else if(array_contains_ic(@qpgroups,"militant")){
                    @combat_title = "militant";
                    @combat_title_description = "a person who lives for battle";
                }else if(array_contains_ic(@qpgroups,"warlord")){
                    @combat_title = "warlord";
                    @combat_title_description = "a master of the battlefield";
                }else{
                    @combat_title = "civilian";
                    @combat_title_description = "a civilian, with little combat experience";
                }

                try{@karma = import('AR.Karma.Players.'.@qdashless)["karma"];} catch(Exception @e){@karma = 0;}
                try{@lov = import('AR.Karma.Players.'.@qdashless)["lov"];} catch(Exception @e){@lov = 0;}
                try{@money_rank = set_placeholders(@query_player,"%xconomy_top_rank%");} catch(Exception @e){@money_rank = "unknown";}
                try{@first_played = simple_date("EEE, d MMM yyyy",pfirst_played(@dashless));} catch(Exception @e){@first_played = "unknown";}
                
                array_push(@messages,_system(yml_encode(associative_array(
                    "name":@player,
                    "world":pworld(@puuid),
                    "rank":vault_pgroup(@player),
                    "karma":@karma,
                    "karma_title":@karma_title,
                    "karma_title_description":@karma_title_description,
                    "combatant_level":@lov,
                    "combat_title":@combat_title,
                    "combat_title_description":@combat_title_description,
                    "xth_richest":@money_rank,
                    "player_since":@first_played
                ),true)));
            default:
        }

        tmsg(@player,color(8)."Sending request to ChatGPT API... @type");
        // This is the actual API call. Copilot keeps autocompleting my comments with "This is a bit of a mess" and I'm not sure how to feel about that.
        http_request(@endpoint,associative_array(
            "method": "GET",
            "headers": @headers,
            "params": json_encode(array(
                "model": @model,
                "messages": @messages,
                "temperature": @crazy,
                "functions": @functions,
                "function_call":"auto",
                "user":@puuid
            )),
            "success": closure(@output){
                //TODO: The try catch here was a catch all but I need to decide how to handle malformed responses. I'm thinking about retrying them by calling this proc recursively, maybe 3 times max, or possibly sending a second request asking ChatGPT to correct it's formatting. 
                try {
                    @body = json_decode(@output["body"]);
                    if(!array_index_exists(@body,"choices") || array_index_exists(@body,"error")){
                        if(@iterate > 0){
                            @error_msg = json_decode(@body["error"])["message"];
                            if(reg_count("The server had an error processing your request.",@error_msg)){
                                if(@private){
                                    tmsg(@player,color(8)."Problem on ChatGPT's end. Trying again.");
                                }else{
                                    broadcast(color(8)."Problem on ChatGPT's end. Trying again.");
                                }
                                sys_out("ChatGPT Exception: \nOutput:".@output["body"]);
                                _message_gpt(@puuid,@input,@npc,@private,@type,@iterate - 1);
                            }else if(reg_count("That model is currently overloaded with other requests.",@error_msg)){
                                if(@private){
                                    tmsg(@player,color(8)."ChatGPT is thinking...");
                                }else{
                                    broadcast(color(8)."ChatGPT is thinking...");
                                }
                                set_timeout(1000 * 15, closure(){
                                    _message_gpt(@puuid,@input,@npc,@private,@type,@iterate - 1);
                                })
                            }
                        }else{
                            if(@private){
                                tmsg(@player,color(8)."There was a problem with the ChatGPT script. giving up.");
                            }else{
                                broadcast(color(8)."There was a problem with the ChatGPT script. giving up.");
                            }
                            sys_out("ChatGPT Exception: \nOutput:".@output["body"]);
                        }
                    }
                    if(!array_index_exists(@body["choices"][0]["message"],"function_call")){
                        // This is a regular conversation response.
                        // Switch based on the finish_reason, if due to length, send a new request with the last message added.
                        @finish_reason = @body["choices"][0]["finish_reason"];
                        if(@type === "continue"){
                            @incomplete = import("ChatGPT.Messages")[array_size(import("ChatGPT.Messages")) - 1];
                            @next = reg_replace("\\w+ to \\w{1,16} at \\d{13}: ","",@body["choices"][0]["message"]["content"]);
                            @response = @incomplete.@next;
                            import("ChatGPT.Messages")[array_size(import("ChatGPT.Messages")) - 1] = @response; 
                        }else{
                            @response = reg_replace("\\w+ to \\w{1,16} at \\d{13}: ","",@body["choices"][0]["message"]["content"]);
                            array_push(import("ChatGPT.Messages"),_assistant(@response,@npc,@player));
                        }
                        _save("ChatGPT.Messages");
                        switch(@finish_reason){
                            case "length":
                                if(@iterate > 0){
                                    _message_gpt(@puuid,"",@npc,@private,"continue",@iterate - 1);
                                }else{
                                    if(@private){
                                        tmsg(@player,@npc_displayname.color(7).": ".@response.color(8)." (Message cut off due to crazy length.)");
                                    }else{
                                        broadcast(@npc_displayname.color(7).": ".@response.color(8)." (Message cut off due to crazy length.)");
                                    }
                                }
                            case "stop":
                                if(@private){
                                    tmsg(@player,@npc_displayname.color(7).": ".@response);
                                }else{
                                    broadcast(@npc_displayname.color(7).": ".@response);
                                }
                            default:
                                if(@private){
                                    tmsg(@player,color(8)."There was a problem with the ChatGPT script. (unexpected finish reason: @finish_reason)");
                                }else{
                                    broadcast(color(8)."There was a problem with the ChatGPT script. (unexpected finish reason: @finish_reason)");
                                }
                        }
                    }else{
                        @args = json_decode(@body["choices"][0]["message"]["function_call"]["arguments"]);
                        if(array_index_exists(@args,"data")){
                            //@puuid,@input,@npc,@private,@type,@iterate
                            if(@iterate > 0){
                                if(@args["data"] === "player_info"){
                                    _message_gpt(@puuid,@args["player"],@npc,@private,@args["data"],@iterate - 1);
                                }else{
                                    _message_gpt(@puuid,"",@npc,@private,@args["data"],@iterate - 1);
                                }
                            }else{
                                if(@private){
                                    tmsg(@player,color(8)."There was a problem with the ChatGPT script. (too many iterations)");
                                }else{
                                    broadcast(color(8)."There was a problem with the ChatGPT script. (too many iterations)");
                                }
                            }
                        }else{
                            broadcast(color(8)."There was a problem with the ChatGPT script. (not conversing or querying).");
                            sys_out("ChatGPT Exception: \nOutput:".@output["body"]);
                        }
                    }
                }catch(Exception @e){
                    //TODO: This is where I need to handle malformed responses. I'm thinking about retrying them by calling this proc recursively, maybe 3 times max, or possibly sending a second request asking ChatGPT to correct it's formatting.
                    sys_out("ChatGPT Exception: \n".@e."\nOutput:".@output["body"]);
                }
            },
            "error": closure(@error){
                //TODO: This is where I need to handle failures due to exceeding token count. I need to reduce token count by trimming the conversation history without losing important data. I'm open to suggestions on how to accomplish that. GPT-4 will have a higher token count, but I don't have a beta key yet.
                msg(color(8)."There was a problem with the ChatGPT script.");
            },
                //TODO: So far we've never had a timeout but I should probably handle that too.
            "timeout": 60
        ));
    });
}


// Ask ChatGPT to summerize the conversation history.
proc _gpt_condense(){
    @model = "gpt-3.5-turbo-0613";
    @endpoint = "https://api.openai.com/v1/chat/completions";
    @apikey = import("AR.Config.ChatGPT.secrets")["openai_api_key"];
    @organization = import("AR.Config.ChatGPT.secrets")["openai_organization"];
    @headers = associative_array(
        "Content-Type": "application/json",
        "Authorization": "Bearer @apikey",
        "OpenAI-Organization": @organization
    );

        @schema_summarize = associative_array(
        "type": "object",
        "properties": associative_array(
            "summary": associative_array("type": "string",
                "description": "A summary of the messages in the conversation log"),
        ),
        "required": array("summary")
    );

    @functions = array(
        associative_array(
            "name": "summarize",
            "parameters":@schema_summarize,
            "description":"Summarize the conversation history in as few words as possible without forgetting details about players, npcs, conversations, or events."
        );
    );

    @messages = import("ChatGPT.Messages");
    
    //array_insert(@messages,_system("Summarize the conversation history in as few words as possible without forgetting details about players, npcs, conversations, or events."));

    http_request(@endpoint,associative_array(
        "method": "GET",
        "headers": @headers,
        "params": json_encode(array(
            "model": @model,
            "messages": @messages,
            "temperature": 0,
            "functions": @functions,
            "function_call":associative_array("name":"summarize"),
        )),
        "success": closure(@output){
            try{
                @body = json_decode(@output["body"]);
                @args = json_decode(@body["choices"][0]["message"]["function_call"]["arguments"]);
                @summary = @args["summary"];
            } catch(Exception @e){
                broadcast("There was a problem with the ChatGPT History Condense script. Chat logs uneffected.");
                sys_out("ChatGPT Exception: \n".@e."\nOutput:".@output["body"]);
                die();
            }
            export("ChatGPT.Messages",array(associative_array(
                "role":"system",
                "content":"History: @summary"
            )));
            _save("ChatGPT.Messages");
            broadcast(color(8)."Chat logs condensed.");

            
        },
        "error": closure(@error){
            _load("ChatGPT.Conversations",array());
            broadcast(color(8)."There was a problem with the ChatGPT History Condense script. Chat logs restored from storage.");
        },
            //TODO: So far we've never had a timeout but I should probably handle that too.
        "timeout": 60
    ))
}

// set_interval(1000 * 2, closure(){
//     @cooldowns = import("ChatGPT.Cooldowns");
//     @npcs = import("AR.Config.ChatGPT")["NPCs"];
//     foreach(@npc:@npc_data in @npcs){
//         if(
//             array_index_exists(@npc_data,"npcid") &&
//             array_contains(ctz_all_npcs(),@npc_data["npcid"]) &&
//             ctz_npc_is_spawned(@npc_data["npcid"]) &&
//             array_index_exists(@npc_data,"proximity_mission")
//         ){
//             @npc_id = @npc_data["npcid"];
//             @entity_Id = ctz_npc_entity_id(@npc_id);
//             @real_location = entity_loc(@entity_Id);
//             @stored_location = ctz_npc_stored_loc(@npc_id);
//             @npc_description = @npc_data["description"];
//             @npc_personality = @npc_data["personality"];
//             @npc_tone = @npc_data["tone"];
//             @npc_relationships = @npc_data["relationships"];
//             @npc_displayname = @npcs[@npc]["displayname"];
//             @game_day = get_world_day('world');
//             if(has_storm('world')){
//                 if(has_thunder('world')){
//                     @weather = "Thunderstorm"
//                 }else{
//                     @weather = "Raining"
//                 }
//             }else{
//                 @weather = "Clear"
//             }
//             @time_of_day = get_world_time('world');
            
//             foreach(@player in players_in_radius(@real_location, 6)){
//                 @proximity_mission = replace(@npc_data["proximity_mission"],'@player',@player);
//                 @puuid = puuid(@player,true);
//                 @cooldown_key = @player."-".@npc;
//                 if(!array_index_exists(@cooldowns,@cooldown_key) || @cooldowns[@cooldown_key] < time()){
//                     @puuid = puuid(@player,true);
//                     @profiles = import("ChatGPT.Profiles");
//                      if(array_index_exists(@profiles,@puuid)){
//                         @profile = @profiles[@puuid];
//                     }else{
//                         @profile = associative_array(
//                             "npc_relationships": associative_array()
//                         );
//                     }
//                     if(@player == "VergilPrime"){
//                         @rank = "owner";
//                         @rank_description = "the owner and head admin of";
//                     }else if(array_contains_ic(vault_pgroup(@player),"admin")){
//                         @rank = "admin";
//                         @rank_description = "an admin, the highest staff rank on";
//                     }else if(array_contains_ic(vault_pgroup(@player),"supermod")){
//                         @rank = "supermod";
//                         @rank_description = "a supermod, the second highest staff rank on";
//                     }else if(array_contains_ic(vault_pgroup(@player),"moderator")){
//                         @rank = "moderator";
//                         @rank_description = "a moderator, the lowest staff rank on";
//                     }else if(array_contains_ic(vault_pgroup(@player),"trusted")){
//                         @rank = "trusted";
//                         @rank_description = "a trusted player on";
//                     }else if(array_contains_ic(vault_pgroup(@player),"trusted")){
//                         @rank = "player";
//                         @rank_description = "a normal player on";
//                     }
//                     if(array_index_exists(@profile["npc_relationships"],@npc)){
//                         @before_relationship = @profile["npc_relationships"][@npc];
//                     }else{
//                         @before_relationship = 50;
//                     }
//                     @conversations = import("ChatGPT.Conversations");

//                     if(_3d_distance(@stored_location,@real_location) < 3){

//     @system_text =
// "You are @npc, @npc_description. Your relationship score with @player, who is @rank_description Angel's Reach, and has a relationship score of @before_relationship. Stay in-character as a resident of Angel's Reach.
// @proximity_mission

// Target Audience: @player, @rank_description Angel's Reach
// Writing Style: @npc_personality
// Emotional Tone: @npc_tone
// Formality Level: Informal
// Narrative Perspective: First person
// Genre: Light-fantasy
// Setting: Angel Peak, Angel's Reach Minecraft Server
// Constraints:
// - Stay in-character, avoid overly formal speech, and do not refer to yourself as AI, NPC, or Bot.
// Other Data:
// - Weather: @weather"
//                     }else{
// @system_text =
// "You are @npc, @npc_description. Your relationship score with @player, who is @rank_description Angel's Reach, and has a relationship score of @before_relationship. Stay in-character as a resident of Angel's Reach.
// Right now you appear to be away from your intended post, if @player is VergilPrime, ask him to respawn you. Otherwise, ask @player to let staff know you're lost.

// Target Audience: @player, @rank_description Angel's Reach
// Writing Style: @npc_personality
// Emotional Tone: @npc_tone
// Formality Level: Informal
// Narrative Perspective: First person
// Genre: Light-fantasy
// Setting: Angel Peak, Angel's Reach Minecraft Server
// Constraints:
// - Stay in-character, avoid overly formal speech, and do not refer to yourself as AI, NPC, or Bot.
// Other Data:
// - Weather: @weather"
//                     }

                    

//                     // There should be no problem updating to GPT-4 if and when I get a beta key. This will increase the token limit!
//                     @model = "gpt-3.5-turbo-0613";
//                     // I was informed that the maximum value for this was 2, but now Github Copilot is telling me that it's 1. That's probably why it was giving me unhinged results before.
//                     @crazy = 1.3; // Keep under 2!
//                     @endpoint = "https://api.openai.com/v1/chat/completions";
//                     @apikey = import("AR.Config.ChatGPT.secrets")["openai_api_key"];
//                     @organization = import("AR.Config.ChatGPT.secrets")["openai_organization"];
//                     @headers = associative_array(
//                         "Content-Type": "application/json",
//                         "Authorization": "Bearer @apikey",
//                         "OpenAI-Organization": @organization
//                     );

//                     //TODO: I plan on having a server-wide NPC here with no relationship score who just monitors chat and helps players with commands and stuff. This is just a placeholder for now.
//                     if(@npc === "" || @npc === null){
//                         @system_text = 
//                             ""
//                     }else{
//                         // If the player has a relationship score with the NPC, use that. Otherwise, use 50 as the neutral score.
//                         if(array_index_exists(@profile["npc_relationships"],@npc)){
//                             @before_relationship = @profile["npc_relationships"][@npc];
//                         }else{
//                             @before_relationship = 50;
//                         }

//                         // This is the schema for the function call to the ChatGPT API. I sometimes get malformed responses anyways.
//                         @schema = associative_array(
//                             "type": "object",
//                             "properties": associative_array(
//                                 "response": associative_array("type": "string",
//                                     "description": "The response from @npc to @player"),
//                                 "relationship": associative_array("type": "number",
//                                     "description": "An integer between 0 and 100 representing how positively @npc feels about @player where 0 is the worst possible relationship, 100 is the best possible relationship. Refered to as the relationship score.")
//                             ),
//                             "required": array("response","relationship")
//                         );

//                     }

//                     // Here we build the messages array by pushing the system text, then each conversation in the conversation array, then the user's input.
//                     @messages = array(
//                         _system(@system_text)
//                     );

//                     foreach(@conversation in @conversations){
//                         if(@conversation["npc"] === @npc && @conversation["player"] === @puuid){
//                             @answernpc = @conversation["npc"];
//                             @pname = _uuidreg_get_name(@conversation["player"])
//                             array_push(@messages,_user(@pname.": ".@conversation["message"]));
//                             array_push(@messages,_assistant(@answernpc.": ".@conversation["response"]));
//                         }else{
//                             @answernpc = @conversation["npc"];
//                             @pname = _uuidreg_get_name(@conversation["player"])
//                             array_push(@messages,_system(@pname." said to ".@answernpc.": ".@conversation["message"]));
//                             array_push(@messages,_system(@answernpc." replied to "@pname.": ".@conversation["response"]));
//                         }
//                     }

//                     array_push(@messages,_user("@player is nearby, you should talk to them."));

//                     // This is the actual API call. Copilot keeps autocompleting my comments with "This is a bit of a mess" and I'm not sure how to feel about that.
//                     http_request(@endpoint,associative_array(
//                         "method": "GET",
//                         "headers": @headers,
//                         "params": json_encode(array(
//                             "model": @model,
//                             "messages": @messages,
//                             "temperature": @crazy,
//                             "functions": array(associative_array("name": "npc_respond", "parameters":@schema)),
//                             "function_call":associative_array("name": "npc_respond")
//                         )),
//                         "success": closure(@output){
//                             //TODO: The try catch here was a catch all but I need to decide how to handle malformed responses. I'm thinking about retrying them by calling this proc recursively, maybe 3 times max, or possibly sending a second request asking ChatGPT to correct it's formatting. 
//                             try {
//                                 @args = json_decode(@output["body"])["choices"][0]["message"]["function_call"]["arguments"];
//                                 @response = json_decode(@args)["response"];
//                                 @after_relationship = json_decode(@args)["relationship"];
//                                 @conversations = import("ChatGPT.Conversations");
//                                 // Not all this data gets used currently
//                                 array_push(@conversations,associative_array(
//                                     "player": @puuid,
//                                     "message": "",
//                                     "npc": @npc,
//                                     "response": @response,
//                                     "before_relationship": @before_relationship,
//                                     "after_relationship": @after_relationship,
//                                     "timestamp": time()
//                                 ));
//                                 _save("ChatGPT.Conversations");
//                                 // Broadcast the NPCs response to the server
//                                 msg(@player)
//                                     tmsg(@player,@npc_displayname.color(7).": ".@response.color(9)." (Type /gpt @npc <message> to respond)");
//                                 // If the relationship score changed, update the profile and save it.
//                                 //TODO: This might be where the empty array is being saved. I need to figure out why. I think github copilot knows because it autocompleted that last sentence.
//                                 if(@after_relationship !== @before_relationship){
//                                     @profile["npc_relationships"][@npc] = @after_relationship;
//                                     @profiles[@puuid] = @profile;
//                                     _save("ChatGPT.Profiles");
//                                 }
//                             }catch(Exception @e){
//                                 //TODO: This is where I need to handle malformed responses. I'm thinking about retrying them by calling this proc recursively, maybe 3 times max, or possibly sending a second request asking ChatGPT to correct it's formatting.
//                                 sys_out("ChatGPT Exception: \n".@e."\nOutput:".@output["body"]);
//                             }
//                         },
//                         "error": closure(@error){
//                             //TODO: This is where I need to handle failures due to exceeding token count. I need to reduce token count by trimming the conversation history without losing important data. I'm open to suggestions on how to accomplish that. GPT-4 will have a higher token count, but I don't have a beta key yet.
//                             msg("There was a problem with the ChatGPT script.");
//                         },
//                             //TODO: So far we've never had a timeout but I should probably handle that too.
//                         "timeout": 60
//                     ))

//                     @cooldowns[@cooldown_key] = time() + 60 * 1000;
//                     _save("ChatGPT.Cooldowns");
//                 }
//             }
//         }
//     }
// })

set_interval(60 * 1000, closure(){
    @messages = import("ChatGPT.Messages");
    // Count characters in conversations and history
    @characters = 0;
    foreach(@message in @messages){
        @characters += length(@message["content"]);
    }

    // If the character count is over 10,000, condense the history.
    if(@characters > 10000){
        broadcast(color(8)."GPT Condenser running.")
        _gpt_condense();
    }
});

//Unregister command fails if the command doesn't exist, so we try it first. If we don't unregister before registering, executor and tab completor don't get updated live.
try(unregister_command("gpt"));
register_command("gpt", associative_array(
    "description": "Chat with GPT-3.5",
    "usage": "/gpt <npc> <message>",
    "permission": "chatgpt.gpt",
    "tabcompleter":closure(@alias,@sender,@args){
        @npcArray = array_keys(import("AR.Config.ChatGPT")["NPCs"]);
        switch(array_size(@args)){
            case 1:
                return(_tabcomplete_list(@args[0],@npcArray));
            default:
                return(all_players());
        }
    },
    "executor": closure(@alias,@sender,@args){
        if(array_size(@args) < 2){
            return(false);
        }else{
            @npc = @args[0];
            @input = array_implode(@args[1..]);
        }

        if(!array_contains(array_keys(import("AR.Config.ChatGPT")["NPCs"]),@npc)){
            msg(color('c')."Invalid NPC. Valid NPCs are: Mistral, Warden, Postman, Rufus, Rolph, Luna, and Gideon.");
            die();
        }

        _message_gpt(puuid(),@input,@npc,false,"conversation",3);
    }
));

//This command clears the conversation history for the player and NPC. It's useful for debugging.
try(unregister_command("gptreset"));
register_command("gptreset", associative_array(
    "description": "Reset NPC memory",
    "usage": "/gptreset",
    "permission": "chatgpt.gptreset",
    "executor": closure(@alias,@sender,@args){
        export("ChatGPT.Messages",array());
        _save("ChatGPT.Messages");
        msg(color(8)."ChatGPT data cleared.");
    }
))


try(unregister_command("gptcondense"));
register_command("gptcondense", associative_array(
    "description": "condense NPC memory",
    "usage": "/gptcondense",
    "permission": "chatgpt.gptcondense",
    "executor": closure(@alias,@sender,@args){
        msg(color(8)."Sending request, please hold...")
        _gpt_condense();
    }
))