%%
%%  wings_ff_wings.erl --
%%
%%     This module contain the functions for reading and writing .wings files.
%%
%%  Copyright (c) 2001-2011 Bjorn Gustavsson
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%
%%     $Id$
%%

-module(wings_ff_wings).
-export([import/2,export/2]).

-include("wings.hrl").
-include("e3d_image.hrl").
-import(lists, [sort/1,reverse/1,foldl/3,any/2,keymember/3,keyfind/3]).

-define(WINGS_HEADER, "#!WINGS-1.0\r\n\032\04").

%% Load a wings file.

import(Name, St) ->
    wings_pb:start(?__(1,"opening wings file")),
    wings_pb:update(0.07, ?__(2,"reading file")),
    wings_pb:done(import_1(Name, St)).

import_1(Name, St0) ->
    case file:read_file(Name) of
	{ok,<<?WINGS_HEADER,Sz:32,Data/binary>>} when byte_size(Data) =:= Sz ->
	    wings_pb:update(0.08, ?__(1,"converting binary")),
	    try binary_to_term(Data) of
		{wings,0,_Shapes} ->
                    {error, ?__(2,"Pre-0.80 Wings format no longer supported.")};
		{wings,1,_,_,_} ->
		    %% Pre-0.92. No longer supported.
                    {error,?__(3,"Pre-0.92 Wings format no longer supported.")};
		{wings,2,{Shapes,Materials,Props}} ->
		    Dir = filename:dirname(Name),
                    import_vsn2(Shapes, Materials, Props, Dir, St0);
		{wings,_,_} ->
		    {error,?__(4,"unknown wings format")};
		Other ->
		    io:format("~P\n", [Other,20]),
                    {error,?__(5,"corrupt Wings file")}
	    catch
		error:badarg ->
                    {error,?__(5,"corrupt Wings file")}
	    end;
	{ok,_Bin} ->
	    {error,?__(6,"not a Wings file (or old Wings format)")};
	{error,Reason} ->
	    {error,file:format_error(Reason)}
    end.

-record(va, {color_lt=none,
	     color_rt=none,
	     uv_lt=none,
	     uv_rt=none}).

import_vsn2(Shapes, Materials0, Props, Dir, St0) ->
    wings_pb:update(0.10, ?__(1,"images and materials")),
    Images = import_images(Dir,Props),
    Materials1 = translate_materials(Materials0),
    Materials2 = translate_map_images(Materials1, Images),
    Materials = translate_object_modes(Materials2, Shapes),
    {St1,NameMap0} = wings_material:add_materials(Materials, St0),
    NameMap1 = gb_trees:from_orddict(sort(NameMap0)),
    NameMap = optimize_name_map(Materials, NameMap1, []),
    St = import_props(Props, St1),
    wings_pb:update(1.0,?__(2,"objects")),
    import_objects(Shapes, NameMap, St).

optimize_name_map([{Name,_}|Ms], NameMap, Acc) ->
    case gb_trees:lookup(Name, NameMap) of
	none ->
	    optimize_name_map(Ms, NameMap, [{Name,Name}|Acc]);
	{value,NewName} ->
	    optimize_name_map(Ms, NameMap, [{Name,NewName}|Acc])
    end;
optimize_name_map([], _, Acc) -> gb_trees:from_orddict(sort(Acc)).

import_objects(Shapes, NameMap, #st{selmode=Mode,shapes=Shs0,onext=Oid0}=St) ->
    {Objs,Oid} = import_objects(Shapes, Mode, NameMap, Oid0, []),
    Shs = gb_trees:from_orddict(gb_trees:to_list(Shs0) ++ Objs),
    St#st{shapes=Shs,onext=Oid}.

import_objects([Sh0|Shs], Mode, NameMap, Oid, ShAcc) ->
    {object,Name,{winged,Es,Fs,Vs,He},Props} = Sh0,
    Etab = import_edges(Es, 0, []),
    %% The 'default' material saved in this .wings file might not
    %% match the current default material, so it could have been
    %% renamed (to 'default2', for instance). We must make sure
    %% that we use the correctly named default material on faces
    %% without explicit material.
    DefaultMat = case gb_trees:lookup(default, NameMap) of
		     none -> default;
		     {value,DefaultMat0} -> DefaultMat0
		 end,
    FaceMat = import_face_mat(Fs, NameMap, DefaultMat, 0, []),
    Vtab = import_vs(Vs, 0, []),
    Htab = gb_sets:from_list(He),
    Perm = import_perm(Props),
    Mirror = proplists:get_value(mirror_face, Props, none),
    Holes = proplists:get_value(holes, Props, []),
    Pst0 = proplists:get_value(plugin_states, Props, []),
    Pst = try gb_trees:from_orddict(Pst0)
	  catch error:_ -> gb_trees:empty()
	  end,
    We = #we{he=Htab,perm=Perm,holes=Holes,pst=Pst,
	     id=Oid,name=Name,mirror=Mirror,mat=FaceMat},
    HiddenFaces = proplists:get_value(num_hidden_faces, Props, 0),
    import_objects(Shs, Mode, NameMap, Oid+1, [{HiddenFaces,We,{Vtab,Etab}}|ShAcc]);
import_objects([], _Mode, _NameMap, Oid, Objs0) ->
    %%io:format("flat_size: ~p\n", [erts_debug:flat_size(Objs0)]),
    Objs = share_list(Objs0),
    %%io:format("size: ~p\n", [erts_debug:size(Objs)]),
    {Objs,Oid}.
    
import_edges([[{edge,Va,Vb,Lf,Rf,Ltpr,Ltsu,Rtpr,Rtsu}]|Es], Edge, Acc) ->
    Rec = #edge{vs=Va,ve=Vb,lf=Lf,rf=Rf,
		ltpr=Ltpr,ltsu=Ltsu,rtpr=Rtpr,rtsu=Rtsu},
    EdgeData = {Rec,none},
    import_edges(Es, Edge+1, [{Edge,EdgeData}|Acc]);
import_edges([E|Es], Edge, Acc) ->
    EdgeData = import_edge(E, none, #va{}),
    import_edges(Es, Edge+1, [{Edge,EdgeData}|Acc]);
import_edges([], _Edge, Acc) -> reverse(Acc).

import_edge([{edge,Va,Vb,Lf,Rf,Ltpr,Ltsu,Rtpr,Rtsu}|T], _, Attrs) ->
    Rec = #edge{vs=Va,ve=Vb,lf=Lf,rf=Rf,
		ltpr=Ltpr,ltsu=Ltsu,rtpr=Rtpr,rtsu=Rtsu},
    import_edge(T, Rec, Attrs);
import_edge([{uv_lt,<<U/float,V/float>>}|T], Rec, Attrs) ->
    import_edge(T, Rec, Attrs#va{uv_lt={U,V}});
import_edge([{uv_rt,<<U/float,V/float>>}|T], Rec, Attrs) ->
    import_edge(T, Rec, Attrs#va{uv_rt={U,V}});
import_edge([{color_lt,<<R:32/float,G:32/float,B:32/float>>}|T], Rec, Attrs) ->
    import_edge(T, Rec, Attrs#va{color_lt={R,G,B}});
import_edge([{color_rt,<<R:32/float,G:32/float,B:32/float>>}|T], Rec, Attrs) ->
    import_edge(T, Rec, Attrs#va{color_rt={R,G,B}});
import_edge([{color,Bin}|T], Rec, Attrs) ->
    %% Old-style vertex colors (pre 0.98.15).
    <<R1/float,G1/float,B1/float,R2/float,G2/float,B2/float>> = Bin,
    import_edge(T, Rec, Attrs#va{color_lt={R1,G1,B1},color_rt={R2,G2,B2}});
import_edge([{uv,Bin}|T], Rec, Attrs) ->
    %% Old-style UV coordinates (pre 0.98.15).
    <<U1/float,V1/float,U2/float,V2/float>> = Bin,
    import_edge(T, Rec, Attrs#va{uv_lt={U1,V1},uv_rt={U2,V2}});
import_edge([_|T], Rec, Attrs) ->
    import_edge(T, Rec, Attrs);
import_edge([], Rec, Attrs) -> {Rec,Attrs}.

import_face_mat([F|Fs], NameMap, Default, Face, Acc) ->
    Mat = import_face_mat_1(F, NameMap, Default),
    import_face_mat(Fs, NameMap, Default, Face+1, [{Face,Mat}|Acc]);
import_face_mat([], _, _, _, Acc) -> reverse(Acc).

import_face_mat_1([{material,Name}|T], NameMap, Default) ->
    %% Silently ignore materials not found in the name map.
    Mat = case gb_trees:lookup(Name, NameMap) of
	      none -> Default;
	      {value,Other} -> Other
	  end,
    import_face_mat_1(T, NameMap, Mat);
import_face_mat_1([_|T], NameMap, Mat) ->
    import_face_mat_1(T, NameMap, Mat);
import_face_mat_1([], _, Mat) -> Mat.

import_vs([Vtx|Vs], V, Acc) -> 
    Rec = import_vertex(Vtx, []),
    import_vs(Vs, V+1, [{V,Rec}|Acc]);
import_vs([], _V, Acc) -> reverse(Acc).

import_vertex([<<X/float,Y/float,Z/float>>|T], _) ->
    import_vertex(T, {X,Y,Z});
import_vertex([_|T], Rec) ->
    import_vertex(T, Rec);
import_vertex([], Rec) -> Rec.

import_perm(Props) ->
    case proplists:get_value(state, Props) of
	undefined -> 0;
	locked -> 1;
	hidden -> 2;
	hidden_locked -> 3;
	{hidden,Mode,Set} -> {Mode,gb_sets:from_list(Set)};
	_Unknown -> 0
    end.

import_props([{selection,{Mode,Sel0}}|Ps], St) ->
    Sel = import_sel(Sel0, St),
    import_props(Ps, St#st{selmode=Mode,sel=Sel});
import_props([{saved_selection,{Mode,Sel0}}|Ps], St0) ->
    Sel = import_sel(Sel0, St0),
    St = new_sel_group(?__(1,"<Stored Selection>"), Mode, Sel, St0),
    import_props(Ps, St);
import_props([{{selection_group,Name},{Mode,Sel0}}|Ps], St0) ->
    Sel = import_sel(Sel0, St0),
    St = new_sel_group(Name, Mode, Sel, St0),
    import_props(Ps, St);
import_props([{lights,Lights}|Ps], St0) ->
    St = wings_light:import(Lights, St0),
    import_props(Ps, St);
import_props([{views,Views}|Ps], St0) ->
    St = wings_view:import_views(Views, St0),
    import_props(Ps, St);
import_props([{current_view,CurrentView}|Ps], #st{views={_,Views}}=St) ->
    import_props(Ps, St#st{views={CurrentView,Views}});
import_props([{palette,Palette}|Ps], St) ->
    import_props(Ps, St#st{pal=Palette});
import_props([{scene_prefs,ScenePrefs}|Ps], St) ->
    lists:foreach(fun({Key,Val}) ->
			  wings_pref:set_scene_value(Key, Val)
		  end,
		  ScenePrefs),
    import_props(Ps, St);
import_props([{plugin_states,Pst0}|Ps], #st{pst=Previous}=St0) ->
    St = try 
	     case gb_trees:keys(Previous) of
		 [] ->
		     Pst = gb_trees:from_orddict(lists:sort(Pst0)),
		     St0#st{pst=Pst};
		 _ when Pst0 =:= [] ->
		     St0;
		 PrevKeys ->
		     M=fun({Mod,Data},Acc) ->
			       case lists:member(Mod,PrevKeys) of
				   true ->
				       try
					   Pst = Mod:merge_st(Data,St0),
					   [{Mod,Pst}|lists:keydelete(Mod,1,Acc)]
				       catch _:_ -> Acc
				       end;
				   false ->
				       [{Mod,Data}|Acc]
			       end
		       end,
		     Pst1 = lists:foldl(M,gb_trees:to_list(Previous),Pst0),
		     Pst  = gb_trees:from_orddict(lists:sort(Pst1)),
		     St0#st{pst=Pst}
	     end
	 catch error:Reason -> 
		 io:format("Failed importing plugins state Not a gb_tree ~p ~n",
			   [Reason]),
		 St0
	 end,
    import_props(Ps,St);
import_props([_|Ps], St) ->
    import_props(Ps, St);
import_props([], St) -> St.

import_sel(Sel, #st{onext=IdBase}) ->
    [{IdBase+Id,gb_sets:from_list(Elems)} || {Id,Elems} <- Sel].

new_sel_group(Name, Mode, Sel, #st{ssels=Ssels0}=St) ->
    Key = {Mode,Name},
    case gb_trees:is_defined(Key, Ssels0) of
	true -> St;
	false ->
	    Ssels = gb_trees:insert(Key, Sel, Ssels0),
	    St#st{ssels=Ssels}
    end.

import_images(Dir,Props) ->
    Empty = gb_trees:empty(),
    case proplists:get_value(images, Props) of
	undefined -> Empty;
	Images -> import_images_1(Images, Dir, Empty)
    end.
	    
import_images_1([{Id0,Im}|T], Dir, Map) ->
    try 
	#e3d_image{name=Name} = E3D = import_image(Im,Dir),
	Id = wings_image:new(Name, E3D),
	import_images_1(T, Dir, gb_trees:insert(Id0, Id, Map))
    catch
	throw:{bad_image,Image} -> 
	    E3d = #e3d_image{name=Image,width=1,height=1,image= <<0,0,0>>},
	    ID = wings_image:new(Image, E3d),
	    import_images_1(T, Dir, gb_trees:insert(Id0, ID, Map))
    end;
import_images_1([], _, Map) -> Map.

import_image(Im,Dir) ->
    Name = proplists:get_value(name, Im, ?__(1,"unnamed image")),
    case proplists:get_value(filename, Im) of
	undefined ->
	    W = proplists:get_value(width, Im, 0),
	    H = proplists:get_value(height, Im, 0),
	    PP = proplists:get_value(samples_per_pixel, Im, 0),
	    Pixels = proplists:get_value(pixels, Im),
	    if
		W*H*PP =:= byte_size(Pixels) -> 
		    ok;
		true -> 
		    Str = io_lib:format(?__(2,"Bad image: ~p\n"), [Name]),
		    wings_u:message(lists:flatten(Str)),
		    throw({bad_image,Name})
	    end,
	    MaskSize = proplists:get_value(mask_size, Im),
	    Type = case PP of
		       1 when MaskSize =:= 1 -> a8;
		       1 -> g8;
		       2 -> g8a8;
		       3 -> r8g8b8;
		       4 -> r8g8b8a8
		   end,
	    #e3d_image{name=Name,width=W,height=H,type=Type,order=lower_left,
		       alignment=1,bytes_pp=PP,image=Pixels};
	Filename ->
	    Ps = [{filename,Filename}, {opt_dir,Dir}],
	    case wings_image:image_read(Ps) of
		#e3d_image{}=E3D ->
		    E3D#e3d_image{name=Name};
		{error,_} ->
		    Str = io_lib:format(?__(2,"Bad image: ~p\n"), [Name]),
		    wings_u:message(lists:flatten(Str)),
		    throw({bad_image,Name})
	    end
    end.

translate_map_images(Mats, ImMap) ->
    [translate_map_images_1(M, ImMap) || M <- Mats].

translate_map_images_1({Name,Props0}=Mat, ImMap) ->
    case proplists:get_value(maps, Props0, []) of
	[] -> Mat;
	Maps ->
	    Props = lists:keydelete(maps, 1, Props0),
	    {Name,[{maps,translate_map_images_2(Maps, Name, ImMap)}|Props]}
    end.

translate_map_images_2([{Type,Im0}|T], Mat, ImMap) when is_integer(Im0) ->
    case gb_trees:lookup(Im0, ImMap) of
	none ->
	    %% Something wrong here.
	    io:format( ?__(1,"Material ~p, ~p texture: reference to non-existing image ~p\n"),
		       [Mat,Type,Im0]),
	    translate_map_images_2(T, Mat, ImMap);
	{value,Im} ->
	    if Type == normal -> wings_image:is_normalmap(Im);
	       true -> ok
	    end,
	    [{Type,Im}|translate_map_images_2(T, Mat, ImMap)]
    end;
translate_map_images_2([H|T], Mat, ImMap) ->
    [H|translate_map_images_2(T, Mat, ImMap)];
translate_map_images_2([], _, _) -> [].

%%%
%%% Sharing of floating point numbers on import.
%%%

share_list(Wes) ->
    Tabs0 = [Tabs || {_,_,{_,_}=Tabs} <- Wes],
    Floats = share_floats(Tabs0, tuple_to_list(wings_color:white())),
    Tabs = share_list_1(Tabs0, Floats, gb_trees:empty(), []),
    share_list_2(Tabs, Wes, []).

share_list_1([{Vtab0,Etab0}|Ts], Floats, Tuples0, Acc) ->
    Vtab = share_vs(Vtab0, Floats, []),
    {Etab,Attr,Tuples} = share_es(Etab0, Floats, [], [], Tuples0),
    share_list_1(Ts, Floats, Tuples, [{Vtab,Etab,Attr}|Acc]);
share_list_1([], _, _, Ts) -> reverse(Ts).

share_list_2([{Vtab0,Etab0,Attr}|Ts],
	     [{NumHidden,#we{id=Id,mat=FaceMat}=We0,_}|Wes], Acc) ->
    Vtab = array:from_orddict(Vtab0),
    Etab = array:from_orddict(Etab0),
    We1 = wings_we:rebuild(We0#we{vp=Vtab,es=Etab,mat=default}),
    We2 = wings_facemat:assign(FaceMat, We1),

    %% Hide invisible faces and set holes.
    We3 = if
	      NumHidden =:= 0 -> We2;
	      true ->
		  Hidden = lists:seq(0, NumHidden-1),
		  Holes = ordsets:from_list([-F-1 || F <- We2#we.holes]),
		  wings_we:hide_faces(Hidden, We2#we{holes=Holes})
	  end,
    We4 = translate_old_holes(We3),
    We5 = validate_holes(We4),

    %% Very old Wings files can have invalid mirror faces for some reason.
    We6 = wings_we:validate_mirror(We5),

    %% Set attributes (if any) for all edges.
    We7 = foldl(fun({E,Lt,Rt}, W) ->
			wings_va:set_both_edge_attrs(E, Lt, Rt, W)
		end, We6, Attr),

    %% At last, hide the virtual mirror face.
    We = case We7 of
	     #we{mirror=none} ->
		 We7;
	     #we{mirror=MirrorFace} ->
		 %% Hide the virtual mirror face.
		 We8 = wings_we:hide_faces([MirrorFace], We7),
		 We8#we{mirror=-MirrorFace-1}
	 end,
    share_list_2(Ts, Wes, [{Id,We}|Acc]);
share_list_2([], [], Wes) -> sort(Wes).

share_floats([{Vtab,Etab}|T], Shared0) ->
    Shared1 = share_floats_1(Vtab, Shared0),
    Shared = share_floats_2(Etab, Shared1),
    share_floats(T, Shared);
share_floats([], Shared0) ->
    Shared1 = ordsets:from_list(Shared0),
    Shared = share_floats_4(Shared1, []),
    gb_trees:from_orddict(Shared).

share_floats_1([{_,{A,B,C}}|T], Shared) ->
    share_floats_1(T, [A,B,C|Shared]);
share_floats_1([], Shared) -> Shared.

share_floats_2([{_,{_,none}}|T], Shared) ->
    share_floats_2(T, Shared);
share_floats_2([{_,{_,#va{}=Va}}|T], Shared0) ->
    Shared1 = share_floats_3(Va#va.color_lt, Shared0),
    Shared2 = share_floats_3(Va#va.color_rt, Shared1),
    Shared3 = share_floats_3(Va#va.uv_lt, Shared2),
    Shared = share_floats_3(Va#va.uv_rt, Shared3),
    share_floats_2(T, Shared);
share_floats_2([], Shared) -> Shared.

share_floats_3({A,B}, [A,B|_]=Shared) -> Shared;
share_floats_3({A,B,C}, [A,B,C|_]=Shared) -> Shared;
share_floats_3({A,B}, Shared) -> [A,B|Shared];
share_floats_3({A,B,C}, Shared) -> [A,B,C|Shared];
share_floats_3(none, Shared) -> Shared.

share_floats_4([F|Fs], Acc) ->
    share_floats_4(Fs, [{F,F}|Acc]);
share_floats_4([], Acc) -> reverse(Acc).

share_vs([{V,{X0,Y0,Z0}}|Vs], Floats, Acc) ->
    X = gb_trees:get(X0, Floats),
    Y = gb_trees:get(Y0, Floats),
    Z = gb_trees:get(Z0, Floats),
    share_vs(Vs, Floats, [{V,{X,Y,Z}}|Acc]);
share_vs([], _, Acc) -> reverse(Acc).

share_es([{E,{Rec,none}}|Vs], Floats, Acc, AttrAcc, Shared) ->
    share_es(Vs, Floats, [{E,Rec}|Acc], AttrAcc, Shared);
share_es([{E,{Rec,Va0}}|Vs], Floats, Acc, AttrAcc0, Shared0) ->
    #va{color_lt=ColLt0,color_rt=ColRt0,
	uv_lt=UvLt0,uv_rt=UvRt0} = Va0,
    {ColLt,Shared1} = share_tuple(ColLt0, Floats, Shared0),
    {ColRt,Shared2} = share_tuple(ColRt0, Floats, Shared1),
    {UvLt,Shared3} = share_tuple(UvLt0, Floats, Shared2),
    {UvRt,Shared} = share_tuple(UvRt0, Floats, Shared3),
    LtAttr = wings_va:new_attr(ColLt, UvLt),
    RtAttr = wings_va:new_attr(ColRt, UvRt),
    AttrAcc = [{E,LtAttr,RtAttr}|AttrAcc0],
    share_es(Vs, Floats, [{E,Rec}|Acc], AttrAcc, Shared);
share_es([], _, Acc, AttrAcc, Shared) ->
    {reverse(Acc),AttrAcc,Shared}.

share_tuple({A0,B0}=Tuple0, Floats, Shared) ->
    case gb_trees:lookup(Tuple0, Shared) of
	none ->
	    A = gb_trees:get(A0, Floats),
	    B = gb_trees:get(B0, Floats),
	    Tuple = {A,B},
	    {Tuple,gb_trees:insert(Tuple, Tuple, Shared)};
	{value,Tuple} -> {Tuple,Shared}
    end;
share_tuple({A0,B0,C0}=Tuple0, Floats, Shared) ->
    case gb_trees:lookup(Tuple0, Shared) of
	none ->
	    A = gb_trees:get(A0, Floats),
	    B = gb_trees:get(B0, Floats),
	    C = gb_trees:get(C0, Floats),
	    Tuple = {A,B,C},
	    {Tuple,gb_trees:insert(Tuple, Tuple, Shared)};
	{value,Tuple} -> {Tuple,Shared}
    end;
share_tuple(none, _, Shared) -> {none,Shared}.

%%%
%%% Import of old materials format (up to and including wings-0.94.02).
%%%

translate_materials(Mats) ->
    [translate_material(M) || M <- Mats].
    
translate_material({Name,Props}=Mat) ->
    case proplists:is_defined(opengl, Props) of
	true -> Mat;
	false ->
	    Opac = proplists:get_value(opacity, Props),
	    {Name,translate_material(Props, Opac, [], [])}
    end.

translate_material([Mat|Mats], Opac, OpenGL, Maps) ->
    case Mat of
	{diffuse_map,Map} ->
	    translate_material(Mats, Opac, OpenGL, [{diffuse,Map}|Maps]);
	{diffuse,_}=Diff ->
	    translate_material(Mats, Opac, [trans(Diff, Opac)|OpenGL], Maps);
	{ambient,_}=Amb ->
	    translate_material(Mats, Opac, [trans(Amb, Opac)|OpenGL], Maps);
	{specular,_}=Spec ->
	    translate_material(Mats, Opac, [trans(Spec, Opac)|OpenGL], Maps);
	{shininess,Sh} ->
	    translate_material(Mats, Opac, [{shininess,1.0-Sh}|OpenGL], Maps);
	_ ->
	    translate_material(Mats, OpenGL, Opac, Maps)
    end;
translate_material([], _, OpenGL, Maps) ->
    [{opengl,OpenGL},{maps,Maps}].

trans({Key,{R,G,B}}, Opac) -> {Key,{R,G,B,Opac}}.

%%
%% Object modes were removed after the 1.1.7 release and
%% replaced with information about vertex colors in the
%% materials. At the same time the 'default' material was
%% changed to show vertex colors for the faces it was applied
%% to.
%%
%% Left alone, there would be two annoyances when loading
%% old models:
%%
%% 1. Vertex colors would not be shown.
%%
%% 2. Since the 'default' materials do not match, the 'default'
%%    material in the file will be renamed to 'default2' (or
%%    something similar) and there would be a new 'default'
%%    material.
%%
%% We will avoid both those annoyances by changing the 'default'
%% material in the file so that it is more likely to match
%% current 'default' material. We will only do this change if
%% the file contains an implicit object mode for some object,
%% i.e. was saved by 1.1.7 or earlier.
%%
translate_object_modes(Mats, Objects) ->
    OldFile = any(fun(Obj) ->
			  {object,_Name,_Winged,Props} = Obj,
			  keymember(mode, 1, Props)
		  end, Objects),
    case OldFile of
	false -> Mats;
	true -> [translate_object_mode(M) || M <- Mats]
    end.

translate_object_mode({default=Name,Props0}) ->
    OpenGL0 = proplists:get_value(opengl, Props0, []),
    OpenGL = [{vertex_colors,set}|OpenGL0],
    Props = [{opengl,OpenGL}|lists:keydelete(opengl, 1, Props0)],
    {Name,Props};
translate_object_mode(Mat) -> Mat.

%%
%% There used to be a '_hole_' material up to the 1.1.10 release.
%% The '_hole_' material was pre-defined and was specially handled
%% when exporting (faces having the material would not be exported)
%% and importing (missing faces would be created and assigned the
%% material).
%%
%% Translate faces with the '_hole_' material to the new type
%% of holes introduced after the 1.1.10 release.
%%
translate_old_holes(#we{holes=[]}=We) ->
    case wings_facemat:is_material_used('_hole_', We) of
	false -> We;
	true -> translate_old_holes_1(We)
    end;
translate_old_holes(We) -> We.

translate_old_holes_1(#we{fs=Ftab}=We0) ->
    MatFaces = wings_facemat:mat_faces(gb_trees:to_list(Ftab), We0),
    {_,Holes0} = keyfind('_hole_', 1, MatFaces),
    Holes = [F || {F,_} <- Holes0],
    We1 = wings_dissolve:faces(Holes, We0),
    NewHoleFaces = wings_we:new_items_as_ordset(face, We0, We1),
    We = wings_facemat:assign(default, NewHoleFaces, We1),
    HiddenNewHoleFaces = ordsets:from_list([-F-1 || F <- NewHoleFaces]),
    wings_we:hide_faces(NewHoleFaces, We#we{holes=HiddenNewHoleFaces}).

%% validate_holes(We0) -> We
%%  Remove any invalid entries in We#we.holes. Ideally, there should
%%  be no invalid entries, but because of bugs there could be.
%%
validate_holes(#we{fs=Ftab,holes=Holes0}=We) ->
    %% Only keep faces that exist and are invisible.
    Holes = [F || F <- Holes0, F < 0, gb_trees:is_defined(F, Ftab)],
    We#we{holes=Holes}.
    
%%%
%%% Save a Wings file (in version 2).
%%%

export(Name, St0) ->
    wings_pb:start( ?__(1,"saving")),
    wings_pb:update(0.01, ?__(2,"lights")),
    Lights = wings_light:export_bc(St0),
    Materials = case wings_pref:get_value(save_unused_materials) of
        true -> 
            #st{mat=Mat} = St0,
            gb_trees:to_list(Mat);
        false -> 
            wings_material:used_materials(St0)
    end,
    #st{shapes=Shs0,views={CurrentView,_}} = St = 
    remove_lights(St0),
    Sel0 = collect_sel(St),
    wings_pb:update(0.65, ?__(3,"renumbering")),
    Shs1 = [{Id,show_mirror_face(We)} ||
	       {Id,We} <- gb_trees:to_list(Shs0)],
    {Shs2,Sel} = renumber(Shs1, Sel0, 0, [], []),
    Shs = foldl(fun shape/2, [], Shs2),
    wings_pb:update(0.98, ?__(4,"objects")),
    Props0 = export_props(Sel),
    Props1 = case Lights of
		 [] -> Props0;
		 [_|_] -> [{lights,Lights}|Props0]
	     end,
    Props2 = case export_images() of
		[] -> Props1;
		Images -> [{images,Images}|Props1]
	     end,
    Props3 = case wings_view:export_views(St) of
		 [] -> Props2;
		 Views -> [{current_view,CurrentView},{views,Views}|Props2]
	     end,
    Props4 = case wings_palette:palette(St) of
		 [] -> Props3;
		 Palette -> [{palette, Palette}|Props3]
	     end,
    Props5 = export_pst(St#st.pst,Props4),
    Props  = [{scene_prefs,wings_pref:get_scene_value()}|Props5],
    Wings = {wings,2,{Shs,Materials,Props}},
    wings_pb:update(0.99, ?__(5,"compressing")),
    Bin = term_to_binary(Wings, [compressed]),
    wings_pb:update(1.0, ?__(6,"writing file")),
    wings_pb:done(write_file(Name, Bin)).

remove_lights(#st{sel=Sel0,shapes=Shs0}=St) ->
    Shs1 = foldl(fun(We, A) when ?IS_ANY_LIGHT(We) -> A;
		    (#we{id=Id}=We, A) -> [{Id,We}|A]
		 end, [], gb_trees:values(Shs0)),
    Shs = gb_trees:from_orddict(reverse(Shs1)),
    Sel = [S || {Id,_}=S <- Sel0, gb_trees:is_defined(Id, Shs)],
    St#st{sel=Sel,shapes=Shs}.

collect_sel(#st{selmode=Mode,sel=Sel0,ssels=Ssels}=St) ->
    Sel1 = [{Id,{Mode,gb_sets:to_list(Elems),selection}} ||
	       {Id,Elems} <- Sel0],
    Sel2 = collect_sel_groups(gb_trees:to_list(Ssels), St, Sel1),
    Sel3 = sofs:relation(Sel2, [{id,data}]),
    Sel = sofs:relation_to_family(Sel3),
    sofs:to_external(Sel).

collect_sel_groups([{{Mode,Name},Sel}|Gs], St, Acc0) ->
    Acc = [{Id,{Mode,gb_sets:to_list(Elems),{selection_group,Name}}} ||
	      {Id,Elems} <- wings_sel:valid_sel(Sel, Mode, St)] ++ Acc0,
    collect_sel_groups(Gs, St, Acc);
collect_sel_groups([], _, Acc) -> Acc.

show_mirror_face(#we{mirror=none}=We) -> We;
show_mirror_face(#we{mirror=Face}=We) ->
    %% The mirror face should not be hidden in a .wings file.
    %% (For compatibility with previous versions.)
    wings_we:show_faces([Face], We#we{mirror=-Face-1}).

renumber([{Id,We0}|Shs], [{Id,Root0}|Sel], NewId, WeAcc, RootAcc) ->
    Hidden = wings_we:num_hidden(We0),
    {We,Root} = wings_we:renumber(We0, 0, Root0),
    renumber(Shs, Sel, NewId+1, [{Hidden,We}|WeAcc],
	     [{NewId,Root}|RootAcc]);
renumber([{_,We0}|Shs], Sel, NewId, WeAcc, RootAcc) ->
    Hidden = wings_we:num_hidden(We0),
    We = wings_we:renumber(We0, 0),
    renumber(Shs, Sel, NewId+1, [{Hidden,We}|WeAcc], RootAcc);
renumber([], [], _NewId, WeAcc, RootAcc) ->
    {WeAcc,RootAcc}.

export_props(Sel0) ->
    Sel1 = sofs:family(Sel0, [{id,[{mode,list,key}]}]),
    Sel2 = sofs:family_to_relation(Sel1),
    Sel3 = sofs:projection(
	     {external,fun({Id,{Mode,Elems,Key}}) ->
			       {{Key,Mode},{Id,Elems}}
		       end}, Sel2),
    Sel = sofs:relation_to_family(Sel3),
    export_props_1(sofs:to_external(Sel), []).

export_props_1([{{What,Mode},Sel}|T], Acc) ->
    export_props_1(T, [{What,{Mode,Sel}}|Acc]);
export_props_1([], Acc) -> Acc.

export_pst(undefined, Props0) -> Props0;
export_pst(Pst0,Props0) ->
    try 
	Pst1 = gb_trees:to_list(Pst0),
	Pst = lists:filter(fun({Mod,_}) when is_atom(Mod) -> true;
			      (_) -> false end, Pst1),
	[{plugin_states,Pst}|Props0]
    catch error:Reason -> 
	    io:format("Failed exporting plugins state NOT a gb_tree ~p ~n",
		      [Reason]),
	    Props0
    end.

write_file(Name, Bin) ->
    Data = <<?WINGS_HEADER,(byte_size(Bin)):32,Bin/binary>>,
    case file:write_file(Name, Data) of
	ok -> ok;
	{error,Reason} -> {error,file:format_error(Reason)}
    end.

shape({Hidden,#we{name=Name,vp=Vs0,es=Es0,he=Htab,pst=Pst}=We}, Acc) ->
    Vs1 = foldl(fun export_vertex/2, [], array:sparse_to_list(Vs0)),
    Vs = reverse(Vs1),
    UvFaces = gb_sets:from_ordset(wings_we:uv_mapped_faces(We)),
    Es1 = array:sparse_foldl(fun(E, Rec, A) ->
				     export_edge(E, Rec, UvFaces, We, A)
			     end, [], Es0),
    Es = reverse(Es1),
    Fs1 = foldl(fun export_face/2, [], wings_facemat:all(We)),
    Fs = reverse(Fs1),
    He = gb_sets:to_list(Htab),
    Props0 = export_perm(We),
    Props1 = hidden_faces(Hidden, Props0),
    Props2 = mirror(We, Props1),
    Props3 = export_holes(We, Props2),
    Props  = export_pst(Pst, Props3),
    [{object,Name,{winged,Es,Fs,Vs,He},Props}|Acc].

mirror(#we{mirror=none}, Props) -> Props;
mirror(#we{mirror=Face}, Props) -> [{mirror_face,Face}|Props].

hidden_faces(0, Props) -> Props;
hidden_faces(N, Props) -> [{num_hidden_faces,N}|Props].

export_holes(#we{holes=[]}, Props) -> Props;
export_holes(#we{holes=Holes}, Props) -> [{holes,Holes}|Props].

export_perm(#we{perm=[]}) ->
    [{state,hidden_locked}];	     %Only for backward compatibility.
export_perm(#we{perm=0}) -> [];
export_perm(#we{perm=1}) -> [{state,locked}];
export_perm(#we{perm=2}) -> [{state,hidden}];
export_perm(#we{perm=3}) -> [{state,hidden_locked}];
export_perm(#we{perm={Mode,Elems}}) ->
    [{state,{hidden,Mode,gb_sets:to_list(Elems)}}].

export_edge(E, Rec, UvFaces, We, Acc) ->
    #edge{vs=Va,ve=Vb,lf=Lf,rf=Rf,
	  ltpr=Ltpr,ltsu=Ltsu,rtpr=Rtpr,rtsu=Rtsu} = Rec,
    Data0 = [{edge,Va,Vb,Lf,Rf,Ltpr,Ltsu,Rtpr,Rtsu}],
    Data = edge_data(E, Rec, We, UvFaces, Data0),
    [Data|Acc].
    
edge_data(E, #edge{lf=Lf,rf=Rf}, We, UvFaces, Acc0) ->
    A = wings_va:edge_attrs(E, left, We),
    B = wings_va:edge_attrs(E, right, We),

    %% If there are both vertex colors and UV coordinates,
    %% we want them in the following order:
    %%   [{color_*,_},{uv_*,_}]
    %% On import in an old version of Wings, the UV coordinates
    %% will be used.
    Acc1 = edge_data_uv(left, Lf, wings_va:attr(uv, A), UvFaces, Acc0),
    Acc2 = edge_data_uv(right, Rf, wings_va:attr(uv, B), UvFaces, Acc1),
    Acc = edge_data_color(left, wings_va:attr(color, A), Acc2),
    edge_data_color(right, wings_va:attr(color, B), Acc).

edge_data_uv(Side, Face, {U,V}, UvFaces, Acc) ->
    case gb_sets:is_member(Face, UvFaces) of
	false -> Acc;
	true when Side =:= left  -> [{uv_lt,<<U/float,V/float>>}|Acc];
	true when Side =:= right -> [{uv_rt,<<U/float,V/float>>}|Acc]
    end;
edge_data_uv(_, _, _, _, Acc) -> Acc.

edge_data_color(left, {R,G,B}, Acc) ->
    [{color_lt,<<R:32/float,G:32/float,B:32/float>>}|Acc];
edge_data_color(right, {R,G,B}, Acc) ->
    [{color_rt,<<R:32/float,G:32/float,B:32/float>>}|Acc];
edge_data_color(_, _, Acc) -> Acc.

export_face({_,default}, Acc) -> [[]|Acc];
export_face({_,Mat}, Acc) -> [[{material,Mat}]|Acc].

export_vertex({X,Y,Z}, Acc) ->
    [[<<X/float,Y/float,Z/float>>]|Acc].

export_images() ->
    export_images_1(wings_image:images()).

export_images_1([{Id,Im}|T]) ->
    [{Id,export_image(Im)}|export_images_1(T)];
export_images_1([]) -> [].

export_image(#e3d_image{filename=none,type=Type0,order=Order}=Im0) ->
    Im = case {export_img_type(Type0),Order} of
	     {Type0=Type,lower_left} -> Im0;
	     {Type,_} -> e3d_image:convert(Im0, Type, 1, lower_left)
	 end,
    #e3d_image{width=W,height=H,bytes_pp=PP,image=Pixels,name=Name} = Im,
    MaskSize = mask_size(Type),
    [{name,Name},{width,W},{height,H},{samples_per_pixel,PP},
     {mask_size,MaskSize},{pixels,Pixels}];
export_image(#e3d_image{name=Name,filename=Filename}=Im) ->
    case filelib:is_file(Filename) of
	false ->
	    export_image(Im#e3d_image{filename=none});
	true ->
	    [{name,Name},{filename,Filename}]
    end.

export_img_type(b8g8r8) -> r8g8b8;
export_img_type(b8g8r8a8) -> r8g8b8a8;
export_img_type(Type) -> Type.

mask_size(r8g8b8a8) -> 1;
mask_size(a8) -> 1;
mask_size(_) -> 0.
